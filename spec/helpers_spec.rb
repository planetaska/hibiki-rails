# frozen_string_literal: true

require "spec_helper"

RSpec.describe Hibiki::Rails::Helpers do
  # The helpers are opt-in instance methods, exactly like Hibiki::DSL.
  let(:view) { Class.new { include Hibiki::Rails::Helpers }.new }

  describe "#hibiki_island" do
    it "stamps the controller, channel, and cid as Stimulus values" do
      expect(view.hibiki_island("CounterChannel", cid: "abc")).to eq(
        { data: { controller: "hibiki",
                  hibiki_channel_value: "CounterChannel",
                  hibiki_cid_value: "abc" } }
      )
    end

    it "accepts the channel class itself" do
      stub_const("TodosChannel", Class.new)
      data = view.hibiki_island(TodosChannel, cid: "abc")[:data]
      expect(data[:hibiki_channel_value]).to eq("TodosChannel")
    end
  end

  describe "#on" do
    it "defaults to the click event" do
      expect(view.on(:increment)).to eq({ data: { hibiki_on: "click->increment" } })
    end

    it "encodes the chosen event into the token" do
      expect(view.on(:set_step, event: :change)[:data][:hibiki_on])
        .to eq("change->set_step")
      expect(view.on(:add, event: :submit)[:data][:hibiki_on])
        .to eq("submit->add")
    end

    it "serializes with: as a JSON payload attribute" do
      expect(view.on(:toggle, with: { index: 3 })[:data]).to eq(
        { hibiki_on: "click->toggle", hibiki_with: '{"index":3}' }
      )
    end

    it "omits the payload attribute when with: is absent" do
      expect(view.on(:increment)[:data]).not_to have_key(:hibiki_with)
    end
  end

  describe "#reactive" do
    it "paints a span placeholder carrying the value id" do
      expect(view.reactive(:doubled, 0))
        .to eq('<span id="hibiki-value-doubled">0</span>')
    end

    it "defaults to an empty placeholder" do
      expect(view.reactive(:doubled)).to eq('<span id="hibiki-value-doubled"></span>')
    end

    it "escapes the placeholder — values are text, not markup" do
      expect(view.reactive(:msg, "<b>hi</b>"))
        .to eq('<span id="hibiki-value-msg">&lt;b&gt;hi&lt;/b&gt;</span>')
    end

    it "accepts an alternate tag name" do
      expect(view.reactive(:step, 1, tag_name: :strong))
        .to eq('<strong id="hibiki-value-step">1</strong>')
    end

    it "rejects a name that is not id-safe" do
      expect { view.reactive("bad name") }.to raise_error(ArgumentError, /name/)
    end

    it "rejects a tag name outside the allowlist" do
      expect { view.reactive(:x, 0, tag_name: "sp an") }
        .to raise_error(ArgumentError, /tag/)
    end
  end

  describe "#reactive_id" do
    it "exposes the value id scheme for hand-stamped placeholders (Phlex)" do
      expect(view.reactive_id(:doubled)).to eq("hibiki-value-doubled")
    end
  end
end
