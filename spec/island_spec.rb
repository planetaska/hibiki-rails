# frozen_string_literal: true

require "rails_helper"

# #island is the ERB spelling of the island root — the cid idiom, the
# hibiki_island splat, and the derived turbo_stream_from folded into one
# block helper — so it needs a real ActionView (capture, tag) plus the Turbo
# stream helper, unlike the bare includer the rest of helpers_spec uses.
class IslandSpecChannel < ActionCable::Channel::Base
  include Hibiki::Rails::Channel

  def build_graph; end
end

module IslandSpec
  class NestedChannel < ActionCable::Channel::Base
    include Hibiki::Rails::Channel

    def build_graph; end
  end
end

RSpec.describe Hibiki::Rails::Helpers, "#island" do
  let(:view) do
    ActionView::Base.with_empty_template_cache.with_view_paths([]).tap do |view|
      view.extend(Turbo::StreamsHelper, described_class)
    end
  end

  def render(erb, **locals) = view.render(inline: erb, locals:)

  def squish(html) = html.gsub(/\s+/, " ").gsub(/>\s+</, "><").strip

  def signed(*streamables) = Turbo::StreamsChannel.signed_stream_name(streamables)

  describe "the default shape" do
    let(:hand_written) do
      render(<<~ERB, cid: "abc")
        <% cid = local_assigns.fetch(:cid) { SecureRandom.uuid } %>
        <%= tag.div(**hibiki_island(IslandSpecChannel, cid:)) do %>
          <%= turbo_stream_from "island_spec", cid %>
          <p>body</p>
        <% end %>
      ERB
    end

    let(:folded) do
      render(<<~ERB, cid: "abc")
        <%= island IslandSpecChannel, cid: local_assigns[:cid] do %>
          <p>body</p>
        <% end %>
      ERB
    end

    it "equals the hand-written three-line form modulo whitespace" do
      expect(squish(folded)).to eq(squish(hand_written))
    end

    it "pins the whole element: root attributes, stream source inside, body" do
      expect(squish(folded)).to eq(
        '<div data-controller="hibiki" data-hibiki-channel-value="IslandSpecChannel" ' \
        'data-hibiki-cid-value="abc">' \
        '<turbo-cable-stream-source channel="Turbo::StreamsChannel" ' \
        "signed-stream-name=\"#{signed('island_spec', 'abc')}\"></turbo-cable-stream-source>" \
        "<p>body</p></div>"
      )
    end

    it "returns html_safe markup" do
      expect(view.island(IslandSpecChannel, cid: "abc") { "x" }).to be_html_safe
    end
  end

  describe "cid" do
    it "yields the cid to the block" do
      html = render(<<~ERB)
        <%= island IslandSpecChannel, cid: "abc" do |cid| %>
          <span id="<%= cid %>"></span>
        <% end %>
      ERB
      expect(html).to include('<span id="abc"></span>')
    end

    it "defaults to a fresh uuid, stamped and yielded alike" do
      yielded = nil
      html = view.island(IslandSpecChannel) do |cid|
        yielded = cid
        ""
      end
      expect(yielded).to match(/\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/)
      expect(html).to include(%(data-hibiki-cid-value="#{yielded}"))
      expect(html).to include(signed("island_spec", yielded))
    end

    it "takes two islands on one page apart" do
      cids = Array.new(2) { view.island(IslandSpecChannel) { |cid| cid } }
      expect(cids.uniq.size).to eq(2)
    end
  end

  describe "options" do
    it "passes params: through to the subscribe-params attribute" do
      html = view.island(IslandSpecChannel, cid: "abc", params: { record_id: 7 }) { "" }
      expect(html).to include(%(data-hibiki-params-value="{&quot;record_id&quot;:7}"))
    end

    it "transport: :broadcast is the default, spelled out or not" do
      spelled = view.island(IslandSpecChannel, cid: "abc", transport: :broadcast) { "" }
      expect(spelled).to eq(view.island(IslandSpecChannel, cid: "abc") { "" })
    end

    it "transport: :transmit leaves the stream source out" do
      html = view.island(IslandSpecChannel, cid: "abc", transport: :transmit) { "<p>body</p>".html_safe }
      expect(html).not_to include("turbo-cable-stream-source")
      expect(squish(html)).to eq(
        '<div data-controller="hibiki" data-hibiki-channel-value="IslandSpecChannel" ' \
        'data-hibiki-cid-value="abc"><p>body</p></div>'
      )
    end

    it "derives a namespaced channel's streamable the way the channel does" do
      html = view.island(IslandSpec::NestedChannel, cid: "abc") { "" }
      expect(html).to include(%(data-hibiki-channel-value="IslandSpec::NestedChannel"))
      expect(html).to include(signed("island_spec:nested", "abc"))
      expect(IslandSpec::NestedChannel.channel_name).to eq("island_spec:nested")
    end

    it "lands tag_name: and other attributes on the root" do
      html = view.island(IslandSpecChannel, cid: "abc", tag_name: :section, class: "card",
                                            id: "books") { "" }
      expect(html).to start_with('<section class="card" id="books" data-controller="hibiki"')
      expect(html).to end_with("</section>")
    end

    it "merges a caller's data: beside the island's, island keys winning" do
      html = view.island(IslandSpecChannel, cid: "abc",
                                            data: { turbo_permanent: true,
                                                    hibiki_cid_value: "spoofed" }) { "" }
      expect(html).to include('data-turbo-permanent="true"')
      expect(html).to include('data-hibiki-cid-value="abc"')
      expect(html).not_to include("spoofed")
    end

    it "rejects a tag name outside the allowlist" do
      expect { view.island(IslandSpecChannel, cid: "abc", tag_name: "di v") { "" } }
        .to raise_error(ArgumentError, /tag/)
    end

    it "rejects an unknown transport by name — no boolean, no Turbo lookalike" do
      expect { view.island(IslandSpecChannel, cid: "abc", transport: :turbo) { "" } }
        .to raise_error(ArgumentError, /transport :turbo must be one of :broadcast, :transmit/)
      expect { view.island(IslandSpecChannel, cid: "abc", transport: false) { "" } }
        .to raise_error(ArgumentError, /transport false/)
    end
  end

  describe "argument validation" do
    it "rejects a String — the block form is class-only" do
      expect { view.island("IslandSpecChannel", cid: "abc") { "" } }
        .to raise_error(ArgumentError, /channel class.*constantize/m)
    end

    it "rejects a Symbol and an instance alike" do
      expect { view.island(:island_spec, cid: "abc") { "" } }
        .to raise_error(ArgumentError, /channel class/)
      expect { view.island(Object.new, cid: "abc") { "" } }
        .to raise_error(ArgumentError, /channel class/)
    end

    it "rejects a class that is not a channel" do
      expect { view.island(String, cid: "abc") { "" } }
        .to raise_error(ArgumentError, /channel class/)
    end

    it "requires a block" do
      expect { view.island(IslandSpecChannel, cid: "abc") }
        .to raise_error(ArgumentError, /block/)
    end

    it "is ERB-only: a bare includer (a Phlex component) is pointed at hibiki_island" do
      bare = Class.new { include Hibiki::Rails::Helpers }.new
      expect { bare.island(IslandSpecChannel, cid: "abc") { "" } }
        .to raise_error(ArgumentError, /ERB-only.*hibiki_island/)
    end
  end
end
