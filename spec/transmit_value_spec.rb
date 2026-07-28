# frozen_string_literal: true

require "rails_helper"

# The channel under test for Channel#transmit_value — the transmit-transport
# half of a single reactive value (Helpers#reactive paints the placeholders).
class ValueTestChannel < ActionCable::Channel::Base
  include Hibiki::Rails::Channel

  def build_graph
    @count = Hibiki::State.new(0)
    @doubled = Hibiki::Derived.new { @count.value * 2 }
    @label = Hibiki::State.new("plain")

    transmit_value(:doubled) { @doubled.value }
    transmit_value(:label) { @label.value }
  end

  def increment = @count.value += 1

  def rewrite_equal = @count.value = @count.value + 1 - 1

  def burst = 10.times { @count.value += 1 }

  def inject = @label.value = %(<script>alert("x")</script>)
end

# The equality gate (§5.12). The value's block reads a version token that a
# "something changed" ping bumps, plus the data whose text it reports — the
# db_version shape the ActiveRecord guide recommends. The effect re-runs on
# every bump; the text only moves when the data does.
class GatedValueChannel < ActionCable::Channel::Base
  include Hibiki::Rails::Channel

  def build_graph
    @version = Hibiki::State.new(0)
    @rows = Hibiki::State.new(%w[a b c])

    transmit_value(:size) do
      @version.value
      @rows.value.size
    end
  end

  def ping = @version.value += 1

  def add_row = @rows.value += ["d"]
end

RSpec.describe ValueTestChannel, type: :channel do
  # FIFO barrier: everything posted before this has run once it returns.
  def drain
    actor = subscription.instance_variable_get(:@__hibiki_actor)
    barrier = Queue.new
    actor.post { barrier << true }
    raise "graph actor did not drain within 2s" unless barrier.pop(timeout: 2)
  end

  def value_transmissions = transmissions.map { it["value"] }

  before do
    subscribe(cid: "c1")
    drain
  end

  it "transmits each value's initial message during build_graph" do
    expect(value_transmissions).to contain_exactly(
      { "name" => "doubled", "text" => "0" },
      { "name" => "label", "text" => "plain" }
    )
  end

  it "matches the name the view-side placeholder stamps (round trip)" do
    view = Class.new { include Hibiki::Rails::Helpers }.new
    placeholder_name = view.reactive(:doubled, 0)[/data-hibiki-value="([^"]+)"/, 1]
    expect(value_transmissions.first["name"]).to eq(placeholder_name)
  end

  it "re-transmits only the affected value's message on a tracked write" do
    perform :increment
    drain
    expect(value_transmissions.count - 2).to eq(1)
    expect(value_transmissions.last).to eq({ "name" => "doubled", "text" => "2" })
  end

  it "does not transmit when a write leaves the value ==-equal" do
    perform :rewrite_equal
    drain
    expect(value_transmissions.count).to eq(2)
  end

  it "coalesces a burst of writes into one transmission" do
    perform :burst
    drain
    expect(value_transmissions.count - 2).to eq(1)
    expect(value_transmissions.last).to eq({ "name" => "doubled", "text" => "20" })
  end

  it "transmits the value verbatim as text — the client assigns textContent" do
    perform :inject
    drain
    expect(value_transmissions.last).to eq(
      { "name" => "label", "text" => %(<script>alert("x")</script>) }
    )
  end

  it "rejects an unsafe value name before creating the effect" do
    expect { subscription.send(:transmit_value, "bad name") { 0 } }
      .to raise_error(ArgumentError, /name/)
  end
end

RSpec.describe GatedValueChannel, type: :channel do
  def drain
    actor = subscription.instance_variable_get(:@__hibiki_actor)
    barrier = Queue.new
    actor.post { barrier << true }
    raise "graph actor did not drain within 2s" unless barrier.pop(timeout: 2)
  end

  def value_transmissions = transmissions.map { it["value"] }

  before do
    subscribe(cid: "c1")
    drain
  end

  it "transmits once on build_graph" do
    expect(value_transmissions).to eq([{ "name" => "size", "text" => "3" }])
  end

  # The effect DOES re-run — a tracked dependency changed — but the text it
  # computes is byte-identical, so the frame is skipped. This is the case the
  # State-level equality gate cannot catch, and is why the gate lives here.
  it "sends nothing when a re-run produces the same text" do
    3.times { perform :ping }
    drain

    expect(value_transmissions.size).to eq(1)
  end

  it "still sends when the text actually changes" do
    perform :ping
    perform :add_row
    drain

    expect(value_transmissions).to eq([
                                        { "name" => "size", "text" => "3" },
                                        { "name" => "size", "text" => "4" }
                                      ])
  end

  it "re-sends after the text returns to a previously transmitted value" do
    perform :add_row
    drain
    subscription.instance_variable_get(:@__hibiki_actor)
                .post { subscription.instance_variable_get(:@rows).value = %w[a b c] }
    drain

    expect(value_transmissions.map { it["text"] }).to eq(%w[3 4 3])
  end
end
