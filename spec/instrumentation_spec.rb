# frozen_string_literal: true

require "rails_helper"

# The events a subscriber can time a graph by. Action Cable's own
# `perform_action.action_cable` covers only the post to the graph thread, so
# the action, its effects and its renders are measured here, where they run.
class InstrumentedChannel < ActionCable::Channel::Base
  include Hibiki::Rails::Channel

  class << self
    attr_accessor :seen
  end

  def build_graph
    @name = Hibiki::State.new("hibiki")
    @page = Hibiki::State.new(1)
    Hibiki::Effect.new { broadcast_replace target: "greeting", html: "<p>#{@name.value}</p>" }
    Hibiki::Effect.new { broadcast_morph target: "pager", html: "<p>#{@page.value}</p>" }
  end

  def rename(data) = @name.value = data["name"]

  def both
    @name.value = "both"
    @page.value += 1
  end

  def same = @name.value = @name.value.dup

  def refresh = broadcast_refresh

  def record(data) = self.class.seen << data

  def boom = raise "instrumented action failed"
end

RSpec.describe InstrumentedChannel, type: :channel do
  def drain
    actor = subscription.instance_variable_get(:@__hibiki_actor)
    barrier = Queue.new
    actor.post { barrier << true }
    raise "graph actor did not drain within 2s" unless barrier.pop(timeout: 2)
  end

  # Every hibiki_rails event published while the block runs, as
  # [name, payload, duration]. The subscriber runs on the graph thread, hence
  # the Queue; the caller drains before the block ends.
  def events
    seen = Queue.new
    subscriber = ActiveSupport::Notifications.subscribe(/\.hibiki_rails\z/) do |event|
      seen << [event.name.delete_suffix(".hibiki_rails"), event.payload, event.duration]
    end
    yield
    Array.new(seen.size) { seen.pop }
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber)
  end

  def named(list, name) = list.select { it.first == name }.map { it[1] }

  describe "subscribing" do
    it "times the graph being built, and the first renders inside it" do
      list = events do
        subscribe(cid: "c1")
        drain
      end

      expect(list.map(&:first)).to eq(%w[render render subscribe])
      expect(named(list, "subscribe")).to eq([{ channel: "InstrumentedChannel" }])
      expect(list.last[2]).to be >= 0
    end

    it "times the dispose" do
      subscribe(cid: "c1")
      drain
      actor = subscription.instance_variable_get(:@__hibiki_actor)

      list = events do
        unsubscribe
        actor.stop(wait: true)
      end

      expect(list.map { it.first(2) }).to eq([["unsubscribe", { channel: "InstrumentedChannel" }]])
    end
  end

  describe "an action" do
    before do
      described_class.seen = []
      subscribe(cid: "c1")
      drain
    end

    it "reports the channel, the action, the wait for the graph thread and the renders it caused" do
      list = events do
        perform :both
        drain
      end
      action = named(list, "action").sole

      expect(action).to include(channel: "InstrumentedChannel", action: "both", renders: 2)
      expect(action[:wait]).to be_a(Float).and(be >= 0)
      # The renders ran inside the action's event, so they are in its duration.
      expect(list.map(&:first)).to eq(%w[render render action])
    end

    it "counts no render for a write the equality gate swallowed" do
      list = events do
        perform :same
        drain
      end

      expect(named(list, "action").sole).to include(action: "same", renders: 0)
    end

    it "counts an immediate refresh" do
      list = events do
        perform :refresh
        drain
      end

      expect(named(list, "action").sole).to include(renders: 1)
    end

    # The name comes from the client; a subscriber that stores it must never
    # be handed an arbitrary string. Action Cable logs the unknown action.
    it "publishes nothing for an action the channel does not have" do
      list = events do
        perform :not_an_action, hbk: 1
        perform :build_graph
        drain
      end

      expect(list).to be_empty
      expect(transmissions.last).to eq({ "ack" => 1 })
    end

    it "still publishes a raising action, with the exception, and still acks" do
      list = events do
        perform :boom, hbk: 2
        drain
      end
      action = named(list, "action").sole

      expect(action).to include(action: "boom", renders: 0)
      expect(action[:exception]).to eq(["RuntimeError", "instrumented action failed"])
      expect(transmissions.last).to eq({ "ack" => 2 })
    end
  end

  describe "a render" do
    before do
      subscribe(cid: "c1")
      drain
    end

    it "names its channel, target and method" do
      list = events do
        perform :both
        perform :refresh
        drain
      end

      expect(named(list, "render")).to eq(
        [
          { channel: "InstrumentedChannel", target: "greeting", method: :replace },
          { channel: "InstrumentedChannel", target: "pager", method: :morph },
          { channel: "InstrumentedChannel", method: :refresh }
        ]
      )
    end

    it "is published around the broadcast, so Action Cable's own event falls inside it" do
      order = Queue.new
      cable = ActiveSupport::Notifications.subscribe("broadcast.action_cable") { order << :broadcast }
      render = ActiveSupport::Notifications.subscribe("render.hibiki_rails") { order << :render }

      perform :rename, name: "world"
      drain

      expect(Array.new(order.size) { order.pop }).to eq(%i[broadcast render])
    ensure
      ActiveSupport::Notifications.unsubscribe(cable)
      ActiveSupport::Notifications.unsubscribe(render)
    end
  end

  # The browser times each trip and reports it with its next action, under
  # the reserved `hbt` key. Anyone can send anything there.
  describe "trips" do
    before do
      described_class.seen = []
      subscribe(cid: "c1")
      drain
    end

    def trips(hbt, action: :same)
      list = events do
        perform action, hbt: hbt
        drain
      end
      named(list, "trip")
    end

    it "publishes one event per trip, before the action that carried them" do
      list = events do
        perform :same, hbt: [["rename", 12, 30], ["same", 4, nil]]
        drain
      end

      expect(list.map(&:first)).to eq(%w[trip trip action])
      expect(named(list, "trip")).to eq(
        [
          { channel: "InstrumentedChannel", action: "rename", ack: 12, paint: 30 },
          { channel: "InstrumentedChannel", action: "same", ack: 4, paint: nil }
        ]
      )
    end

    it "keeps the list out of the action method's data, reported or not" do
      perform :record, hbt: [["rename", 1, 2]], title: "Ice Fire"
      perform :record, hbt: "junk"
      drain

      expect(described_class.seen).to eq([{ "action" => "record", "title" => "Ice Fire" }, { "action" => "record" }])
    end

    it "takes the first five" do
      expect(trips(Array.new(8) { ["same", it, nil] }).map { it[:ack] }).to eq([0, 1, 2, 3, 4])
    end

    it "drops a trip for an action the channel does not have" do
      expect(trips([["not_an_action", 1, 2], ["build_graph", 1, 2], [nil, 1, 2], ["same", 1, 2]]).size).to eq(1)
    end

    it "drops a trip whose times are not numbers" do
      malformed = [["same", "12", 3], ["same", nil, 3], ["same", 1, "3"], ["same", [1], 3], "same", ["same"], nil]

      expect(trips(malformed)).to be_empty
    end

    it "clamps the times to a minute" do
      expect(trips([["same", -5, 90_000.5]])).to eq(
        [{ channel: "InstrumentedChannel", action: "same", ack: 0, paint: 60_000 }]
      )
    end

    it "ignores anything that is not a list" do
      expect(trips({ "0" => ["same", 1, 2] })).to be_empty
      expect(trips("same")).to be_empty
    end
  end
end

RSpec.describe Hibiki::Rails::Broadcasts, "render events" do
  let(:harness) do
    Class.new do
      include Hibiki::Rails::Broadcasts

      public :broadcast_morph

      def self.name = "BcChannel"
      def stream_name = %w[bc c1]
      def params = { cid: "c1" }
    end.new
  end

  # A morph asked for through the caller's own attributes is still a morph.
  it "reads the method from the stream attributes" do
    seen = []
    subscriber = ActiveSupport::Notifications.subscribe("render.hibiki_rails") { seen << it.payload }

    harness.broadcast_morph(target: "a", html: "<p>x</p>", attributes: { "data-note": "mine" })

    expect(seen).to eq([{ channel: "BcChannel", target: "a", method: :morph }])
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber)
  end
end
