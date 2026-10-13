# frozen_string_literal: true

require "rails_helper"

# Action Cable hands every websocket message to a worker pool
# (Connection#receive is send_async), so two actions the client sends back to
# back can reach perform_action in either order. The client numbers them
# under `hbk`, from 1 per subscription, and the channel posts them to the
# graph in that order.
class OrderTestChannel < ActionCable::Channel::Base
  include Hibiki::Rails::Channel

  class << self
    attr_accessor :seen
  end

  def build_graph
    Hibiki.on_cleanup { self.class.seen << "disposed" }
  end

  def note(data) = self.class.seen << data["at"]
end

RSpec.describe OrderTestChannel, type: :channel do
  def acks = transmissions.filter_map { it["ack"] }

  def seen = described_class.seen

  # Wait for the graph thread to have run `count` actions.
  def settle(count)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 2
    sleep 0.005 until seen.size >= count || Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
  end

  before do
    stub_const("Hibiki::Rails::ActionOrder::GRACE", 0.05)
    described_class.seen = []
    subscribe(cid: "c1")
  end

  # The regression: reverb's wizard sent the typed field and Next in one tick,
  # the pool swapped them, and Next ran against the old value.
  it "runs two swapped actions in the order the client sent them" do
    perform :note, at: "next", hbk: 2
    perform :note, at: "set_field", hbk: 1
    settle 2

    expect(seen).to eq(%w[set_field next])
    expect(acks).to eq([1, 2])
  end

  it "holds an action that is ahead of its turn, without running it" do
    perform :note, at: "third", hbk: 3
    perform :note, at: "first", hbk: 1
    settle 1

    expect(seen).to eq(%w[first])
    expect(acks).to eq([1])

    perform :note, at: "second", hbk: 2
    settle 3

    expect(seen).to eq(%w[first second third])
    expect(acks).to eq([1, 2, 3])
  end

  # A number the client never sent (a client older than the fix, after a
  # reconnect) must not hang the ones behind it.
  it "gives up on a missing action after the grace, and runs what it held" do
    perform :note, at: "fifth", hbk: 5
    perform :note, at: "fourth", hbk: 4
    expect(seen).to be_empty

    settle 2

    expect(seen).to eq(%w[fourth fifth])
    expect(acks).to eq([4, 5])
  end

  it "runs a late action at once, and keeps order from there" do
    perform :note, at: "second", hbk: 2
    settle 1
    perform :note, at: "late first", hbk: 1
    perform :note, at: "fourth", hbk: 4
    perform :note, at: "third", hbk: 3
    settle 4

    expect(seen).to eq(["second", "late first", "third", "fourth"])
    expect(acks).to eq([2, 1, 3, 4])
  end

  # A ChannelController subclass, or app code calling the subscription.
  it "passes an action with no number straight through" do
    perform :note, at: "held", hbk: 2
    perform :note, at: "plain"
    settle 1

    expect(seen).to eq(%w[plain])
    expect(acks).to be_empty
  end

  # The number is the client's: one that is not a count is acked as before
  # and takes no turn.
  it "passes a number that is not an integer straight through" do
    perform :note, at: "odd", hbk: "7"
    perform :note, at: "first", hbk: 1
    settle 2

    expect(seen).to eq(%w[odd first])
    expect(acks).to eq(["7", 1])
  end

  it "runs a repeated number at once and loses neither" do
    perform :note, at: "a", hbk: 2
    perform :note, at: "b", hbk: 2
    perform :note, at: "first", hbk: 1
    settle 3

    expect(seen).to eq(%w[b first a])
    expect(acks).to eq([2, 1, 2])
  end

  it "runs what it holds, in order, before the graph is disposed" do
    perform :note, at: "third", hbk: 3
    perform :note, at: "second", hbk: 2
    actor = subscription.instance_variable_get(:@__hibiki_actor)

    unsubscribe
    actor.stop(wait: true)

    expect(seen).to eq(%w[second third disposed])
  end

  it "answers an action that arrives after the unsubscribe with dropped" do
    actor = subscription.instance_variable_get(:@__hibiki_actor)
    unsubscribe
    actor.stop(wait: true)

    subscription.perform_action("action" => "note", "hbk" => 9)

    expect(transmissions.last).to eq({ "ack" => 9, "dropped" => true })
  end

  # perform_action runs on pool threads, several at once.
  it "keeps the order when the actions arrive on many threads" do
    count = 200
    (1..count).to_a.shuffle.each_slice(25).map do |slice|
      Thread.new { slice.each { subscription.perform_action("action" => "note", "at" => it, "hbk" => it) } }
    end.each(&:join)
    settle count

    expect(seen).to eq((1..count).to_a)
    expect(acks).to eq((1..count).to_a)
  end
end

RSpec.describe Hibiki::Rails::ActionOrder do
  subject(:order) { described_class.new }

  let(:ran) { [] }

  before { stub_const("Hibiki::Rails::ActionOrder::GRACE", 0.05) }

  # One grace for one gap: later arrivals behind the same gap do not restart
  # the wait.
  it "does not extend the grace when more arrive behind the same gap" do
    order.submit(3) { ran << 3 }
    sleep 0.03
    order.submit(4) { ran << 4 }
    sleep 0.035

    expect(ran).to eq([3, 4])
  end

  it "waits a fresh grace for a second gap" do
    order.submit(2) { ran << 2 }
    order.submit(4) { ran << 4 }
    sleep 0.07
    expect(ran).to eq([2])

    sleep 0.06
    expect(ran).to eq([2, 4])
  end
end
