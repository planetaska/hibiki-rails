# frozen_string_literal: true

require "rails_helper"

# The channel under test for Channel#transmit_url — mirroring graph state
# into the page's address bar (the client history.replaceState's to it).
class UrlTestChannel < ActionCable::Channel::Base
  include Hibiki::Rails::Channel

  def build_graph
    @page = Hibiki::State.new(1)
    @query = Hibiki::State.new("")

    # The db_version shape: a bumped token re-runs the effect; the URL only
    # moves when the params it names do.
    @version = Hibiki::State.new(0)

    transmit_url do
      @version.value
      params = {}
      params[:query] = @query.value unless @query.value.empty?
      params[:page] = @page.value unless @page.value == 1
      params.empty? ? "/songs" : "/songs?#{params.map { "#{it[0]}=#{it[1]}" }.join('&')}"
    end
  end

  def go_to_page(data) = @page.value = data["page"].to_i

  def search(data) = @query.value = data["query"].to_s

  def ping = @version.value += 1

  def burst = 10.times { @page.value += 1 }
end

# The same mirror, each move a history entry.
class PushUrlTestChannel < ActionCable::Channel::Base
  include Hibiki::Rails::Channel

  def build_graph
    @step = Hibiki::State.new(1)
    transmit_url(history: :push) { "/wizard?step=#{@step.value}" }
  end

  def turn(data) = @step.value = data["step"].to_i
end

RSpec.describe UrlTestChannel, type: :channel do
  # FIFO barrier: everything posted before this has run once it returns.
  def drain
    actor = subscription.instance_variable_get(:@__hibiki_actor)
    barrier = Queue.new
    actor.post { barrier << true }
    raise "graph actor did not drain within 2s" unless barrier.pop(timeout: 2)
  end

  def url_transmissions = transmissions.filter_map { it["url"] }

  before do
    subscribe(cid: "c1")
    drain
  end

  it "transmits the initial URL during build_graph" do
    expect(url_transmissions).to eq(["/songs"])
  end

  it "asks for no history entry by default" do
    expect(transmissions).to all(eq({ "url" => "/songs" }))
  end

  it "re-transmits when a tracked write moves the URL" do
    perform :go_to_page, { "page" => 3 }
    drain
    expect(url_transmissions).to eq(["/songs", "/songs?page=3"])
  end

  it "tracks every signal the block reads" do
    perform :search, { "query" => "x" }
    drain
    expect(url_transmissions.last).to eq("/songs?query=x")
  end

  it "coalesces a burst of writes into one transmission" do
    perform :burst
    drain
    expect(url_transmissions).to eq(["/songs", "/songs?page=11"])
  end

  # The effect DOES re-run — a tracked dependency changed — but the URL it
  # computes is byte-identical, so the frame is skipped (the transmit_value
  # equality gate, same rationale).
  it "sends nothing when a re-run produces the same URL" do
    3.times { perform :ping }
    drain
    expect(url_transmissions.size).to eq(1)
  end
end

RSpec.describe PushUrlTestChannel, type: :channel do
  def drain
    actor = subscription.instance_variable_get(:@__hibiki_actor)
    barrier = Queue.new
    actor.post { barrier << true }
    raise "graph actor did not drain within 2s" unless barrier.pop(timeout: 2)
  end

  it "marks every frame as a history entry" do
    subscribe(cid: "c1")
    perform :turn, { "step" => 2 }
    drain
    expect(transmissions.select { it.key?("url") }).to eq(
      [{ "url" => "/wizard?step=1", "push" => true }, { "url" => "/wizard?step=2", "push" => true }]
    )
  end

  it "refuses a history mode it does not know" do
    expect { Hibiki::Rails::Channel.url_frame(:pushy) }
      .to raise_error(ArgumentError, /history :pushy must be one of :replace, :push/)
  end
end
