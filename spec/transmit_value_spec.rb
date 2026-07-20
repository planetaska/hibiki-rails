# frozen_string_literal: true

require "rails_helper"

# The channel under test for Channel#transmit_value — the transmit-transport
# half of a single reactive value (Helpers#reactive paints the placeholder).
class ValueTestChannel < ActionCable::Channel::Base
  include Hibiki::Rails::Channel

  def build_graph
    @count = Hibiki::State.new(0)
    @doubled = Hibiki::Derived.new { @count.value * 2 }
    @label = Hibiki::State.new("plain")

    transmit_value(:doubled) { @doubled.value }
    transmit_value(:label, tag_name: :strong) { @label.value }
  end

  def increment = @count.value += 1

  def rewrite_equal = @count.value = @count.value + 1 - 1

  def burst = 10.times { @count.value += 1 }

  def inject = @label.value = %(<script>alert("x")</script>)
end

RSpec.describe ValueTestChannel, type: :channel do
  # FIFO barrier: everything posted before this has run once it returns.
  def drain
    actor = subscription.instance_variable_get(:@__hibiki_actor)
    barrier = Queue.new
    actor.post { barrier << true }
    raise "graph actor did not drain within 2s" unless barrier.pop(timeout: 2)
  end

  def html_transmissions = transmissions.map { it["html"] }

  before do
    subscribe(cid: "c1")
    drain
  end

  it "transmits each value's initial fragment during build_graph" do
    expect(html_transmissions).to contain_exactly(
      '<span id="hibiki-value-doubled">0</span>',
      '<strong id="hibiki-value-label">plain</strong>'
    )
  end

  it "matches the id the view-side placeholder paints (round trip)" do
    view = Class.new { include Hibiki::Rails::Helpers }.new
    placeholder_id = view.reactive(:doubled, 0)[/id="([^"]+)"/, 1]
    expect(html_transmissions.first).to include(%(id="#{placeholder_id}"))
  end

  it "re-transmits only the affected value's fragment on a tracked write" do
    perform :increment
    drain
    expect(html_transmissions.count - 2).to eq(1)
    expect(html_transmissions.last).to eq('<span id="hibiki-value-doubled">2</span>')
  end

  it "does not transmit when a write leaves the value ==-equal" do
    perform :rewrite_equal
    drain
    expect(html_transmissions.count).to eq(2)
  end

  it "coalesces a burst of writes into one transmission" do
    perform :burst
    drain
    expect(html_transmissions.count - 2).to eq(1)
    expect(html_transmissions.last).to eq('<span id="hibiki-value-doubled">20</span>')
  end

  it "escapes the value — text, not markup" do
    perform :inject
    drain
    expect(html_transmissions.last).to eq(
      '<strong id="hibiki-value-label">&lt;script&gt;alert(&quot;x&quot;)&lt;/script&gt;</strong>'
    )
  end
end
