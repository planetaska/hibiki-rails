# frozen_string_literal: true

require "rails_helper"

# The post-batch ack: the client stamps a sequence number under the reserved
# `hbk` key and the channel sends `{ack: seq}` back once every effect that
# action was going to run has run. It exists because the core's equality gate
# lets an ordinary action produce ZERO bytes — so a pending indicator that
# waited for a render would hang forever.
class AckTestChannel < ActionCable::Channel::Base
  include Hibiki::Rails::Channel

  class << self
    attr_accessor :seen
  end

  def build_graph
    @count = Hibiki::State.new(0)
    transmit_value(:count) { @count.value }
  end

  def increment = @count.value += 1

  # The zero-render case in miniature: a write the equality gate swallows.
  def no_op = @count.value = @count.value + 1 - 1

  def record(data) = self.class.seen << data

  def boom = raise "ack action failed"
end

RSpec.describe AckTestChannel, type: :channel do
  # FIFO barrier: everything posted before this has run once it returns.
  def drain
    actor = subscription.instance_variable_get(:@__hibiki_actor)
    barrier = Queue.new
    actor.post { barrier << true }
    raise "graph actor did not drain within 2s" unless barrier.pop(timeout: 2)
  end

  def acks = transmissions.filter_map { it["ack"] }

  before do
    described_class.seen = []
    subscribe(cid: "c1")
    drain
  end

  # Backward compatibility, and the reason the whole feature is opt-in from
  # the client: a 0.3.0 page stamps no seq and gets exactly what it did before.
  it "sends no ack for an action that carries no seq" do
    perform :increment
    drain

    expect(acks).to be_empty
  end

  it "sends exactly one ack, after the effects the action triggered" do
    perform :increment, hbk: 7
    drain

    expect(acks).to eq([7])
    expect(transmissions.last).to eq({ "ack" => 7 })
    expect(transmissions[-2]["value"]).to eq({ "name" => "count", "text" => "1" })
  end

  # The whole point. An action the equality gate swallows sends no frame of
  # its own, so the ack is the only thing that can stop the indicator.
  it "acks an action that produces no render at all" do
    perform :no_op, hbk: 1
    drain

    expect(transmissions.size).to eq(2) # the build_graph value, then the ack
    expect(transmissions.last).to eq({ "ack" => 1 })
  end

  # GraphActor#work rescues around the whole job, so without the ensure a
  # raising action would hang the indicator — in exactly the case where Phase 1
  # made the failure a dev-log line with no visible effect.
  it "still acks a raising action, and still reports the error" do
    reporter = Class.new do
      def reports = @reports ||= []
      def report(error, **kwargs) = reports << [error, kwargs]
    end.new
    Rails.error.subscribe(reporter)

    perform :boom, hbk: 2
    drain

    expect(acks).to eq([2])
    expect(reporter.reports.dig(0, 0)&.message).to eq("ack action failed")
  ensure
    Rails.error.unsubscribe(reporter)
  end

  # An unknown action never reaches the graph, but the client is still waiting
  # on it: ActionCable logs and returns, and the ensure fires anyway.
  it "acks an action ActionCable refuses to process" do
    perform :not_an_action, hbk: 3
    drain

    expect(acks).to eq([3])
  end

  # `delete`, not `[]` — the seq is transport bookkeeping and must not turn up
  # as an attribute in a form submission.
  it "keeps the seq out of the action method's data" do
    perform :record, hbk: 4, title: "Ice Fire"
    drain

    expect(described_class.seen).to eq([{ "action" => "record", "title" => "Ice Fire" }])
  end

  # post returns false once the queue is closed: the block never runs, so its
  # ensure never runs either. `dropped` tells the client nothing is coming, so
  # it settles now rather than waiting out its grace window.
  it "acks with dropped: true when the actor is already stopped" do
    subscription.instance_variable_get(:@__hibiki_actor).stop(wait: true)

    perform :increment, hbk: 5

    expect(transmissions.last).to eq({ "ack" => 5, "dropped" => true })
  end
end

RSpec.describe AckTestChannel, "with no graph actor", type: :channel do
  # A rejected subscription leaves @__hibiki_actor nil, and `&.post` yields nil
  # — the same unreachable-ensure hole as a closed queue, and the one the
  # connect-window drop lands in.
  it "acks with dropped: true when the subscription was rejected" do
    subscribe # no cid
    expect(subscription).to be_rejected

    subscription.perform_action("action" => "increment", "hbk" => 6)

    expect(transmissions.last).to eq({ "ack" => 6, "dropped" => true })
  end

  it "still sends nothing when a dropped action carries no seq" do
    subscribe
    subscription.perform_action("action" => "increment")

    expect(transmissions).to be_empty
  end
end
