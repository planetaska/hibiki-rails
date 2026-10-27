# frozen_string_literal: true

require "rails_helper"

# A replaceable action sets state outright from its payload, so when the next
# action released for the subscription is another of its kind, running the
# first is wasted work. Each example holds the graph thread on `hold` (hbk 1)
# so the actions behind it queue up, as they do on a server past its limit.
class ReplaceableChannel < ActionCable::Channel::Base
  include Hibiki::Rails::Channel

  replaceable :search, :change_field

  class << self
    attr_accessor :seen, :gate
  end

  def build_graph
    Hibiki.on_cleanup { self.class.seen << "disposed" }
  end

  def hold = self.class.gate.pop(timeout: 2)

  def search(data) = self.class.seen << "search #{data['q']}"

  def change_field(data) = self.class.seen << "change_field #{data.except('action').to_a.flatten.join('=')}"

  def note(data) = self.class.seen << "note #{data['at']}"
end

RSpec.describe ReplaceableChannel, type: :channel do
  def acks = transmissions.select { it.key?("ack") }

  def seen = described_class.seen

  def actor = subscription.instance_variable_get(:@__hibiki_actor)

  # Let the held graph go, and wait for everything posted to have run.
  def release
    described_class.gate << true
    barrier = Queue.new
    actor.post { barrier << true }
    raise "graph actor did not drain within 2s" unless barrier.pop(timeout: 2)
  end

  before do
    stub_const("Hibiki::Rails::ActionOrder::GRACE", 0.05)
    described_class.seen = []
    described_class.gate = Queue.new
    subscribe(cid: "c1")
    perform :hold, hbk: 1
  end

  # An example that never releases must not leave the graph waiting.
  after { described_class.gate << true }

  it "skips an action when the next one released is the same kind" do
    perform :search, q: "a", hbk: 2
    perform :search, q: "ab", hbk: 3
    release

    expect(seen).to eq(["search ab"])
    expect(acks).to eq([{ "ack" => 1 }, { "ack" => 2, "dropped" => true }, { "ack" => 3 }])
  end

  it "skips a whole run of them but the last" do
    (2..5).each { perform :search, q: "q#{it}", hbk: it }
    release

    expect(seen).to eq(["search q5"])
    expect(acks.count { it["dropped"] }).to eq(3)
  end

  # The looser rule would run `note` against a query the visitor never saw.
  it "skips nothing across a different action" do
    perform :search, q: "a", hbk: 2
    perform :note, at: "save", hbk: 3
    perform :search, q: "ab", hbk: 4
    release

    expect(seen).to eq(["search a", "note save", "search ab"])
    expect(acks.none? { it["dropped"] }).to be(true)
  end

  # Inline Edit: one action on every field, each send naming only its own.
  it "keeps the same action with different payload keys" do
    perform :change_field, name: "Ada", hbk: 2
    perform :change_field, notes: "hi", hbk: 3
    release

    expect(seen).to eq(["change_field name=Ada", "change_field notes=hi"])
  end

  it "never skips an action the channel did not declare" do
    perform :note, at: "one", hbk: 2
    perform :note, at: "two", hbk: 3
    release

    expect(seen).to eq(["note one", "note two"])
  end

  it "decides by number, not by arrival" do
    perform :search, q: "ab", hbk: 3
    perform :search, q: "a", hbk: 2
    release

    expect(seen).to eq(["search ab"])
    expect(acks.last(2)).to eq([{ "ack" => 2, "dropped" => true }, { "ack" => 3 }])
  end

  # Without a number there is no order to trust.
  it "never skips an action with no number, which shields the one before it" do
    perform :search, q: "a", hbk: 2
    perform :search, q: "plain"
    perform :search, q: "ab", hbk: 3
    release

    expect(seen).to eq(["search a", "search plain", "search ab"])
  end

  it "does not skip an action that has already started" do
    perform :search, q: "a", hbk: 2
    release
    perform :search, q: "ab", hbk: 3
    release

    expect(seen).to eq(["search a", "search ab"])
  end

  it "still runs the last action and disposes after it on unsubscribe" do
    perform :search, q: "a", hbk: 2
    perform :search, q: "ab", hbk: 3
    graph = actor

    unsubscribe
    described_class.gate << true
    graph.stop(wait: true)

    expect(seen).to eq(["search ab", "disposed"])
  end

  describe "events" do
    def events
      seen = Queue.new
      subscriber = ActiveSupport::Notifications.subscribe(/\.hibiki_rails\z/) do |event|
        seen << [event.name.delete_suffix(".hibiki_rails"), event.payload]
      end
      yield
      Array.new(seen.size) { seen.pop }
    ensure
      ActiveSupport::Notifications.unsubscribe(subscriber)
    end

    it "publishes a skip, not an action, and keeps the trips it carried" do
      list = events do
        perform :search, q: "a", hbk: 2, hbt: [["search", 12, 30]]
        perform :search, q: "ab", hbk: 3
        release
      end

      list = list.reject { it.first == "subscribe" || it.last[:action] == "hold" }

      expect(list.map(&:first)).to eq(%w[trip skip action])
      expect(list[0].last).to eq({ channel: "ReplaceableChannel", action: "search", ack: 12, paint: 30 })
      expect(list[1].last).to match({ channel: "ReplaceableChannel", action: "search", wait: be >= 0 })
      expect(list[2].last).to include(action: "search")
    end
  end

  describe ".replaceable" do
    it "adds nothing the client can call" do
      expect(described_class.action_methods).to contain_exactly("hold", "search", "change_field", "note")
    end

    it "is inherited, and a subclass adds to it" do
      child = Class.new(described_class) do
        replaceable :note
      end

      expect(child.replaceable_actions).to contain_exactly("search", "change_field", "note")
      expect(described_class.replaceable_actions).to contain_exactly("search", "change_field")
    end
  end
end

# The name is checked at subscribe, since the macro may sit above the methods.
class MisspelledReplaceableChannel < ActionCable::Channel::Base
  include Hibiki::Rails::Channel

  replaceable :serach

  def build_graph; end

  def search(_data) = nil
end

RSpec.describe MisspelledReplaceableChannel, type: :channel do
  it "raises for a name that is not an action" do
    expect { subscribe(cid: "c1") }.to raise_error(ArgumentError, /serach/)
  end
end

RSpec.describe Hibiki::Rails::Replacement do
  subject(:replacement) { described_class.new }

  it "replaces a queued slot with the next of its kind" do
    first = replacement.enter(:k)
    replacement.enter(:k)

    expect(first.start).to be(false)
  end

  # The race: the graph thread starts the job as a cable thread replaces it.
  it "does not replace a slot that has started" do
    first = replacement.enter(:k)
    expect(first.start).to be(true)

    second = replacement.enter(:k)

    expect(second.start).to be(true)
  end

  it "keeps a slot behind which a different kind arrived" do
    first = replacement.enter(:k)
    replacement.enter(:other)
    replacement.enter(:k)

    expect(first.start).to be(true)
  end

  it "gives no slot to an action of no kind, which still shields the one before" do
    first = replacement.enter(:k)

    expect(replacement.enter(nil)).to be_nil
    replacement.enter(:k)
    expect(first.start).to be(true)
  end
end
