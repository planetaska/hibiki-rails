# frozen_string_literal: true

require "spec_helper"

RSpec.describe Hibiki::Rails::Commands do
  subject(:js) { described_class.new }

  it "starts empty and never changes in place" do
    longer = js.hide("#panel")

    expect(js).to be_empty
    expect(js).to be_frozen
    expect(longer.ops).to eq([["hide", { "to" => "#panel" }]])
  end

  it "keeps the commands in the order they were added" do
    chain = js.hide("#panel").add_class("open", to: "#nav").push(:cancel)

    expect(chain.ops.map(&:first)).to eq(%w[hide add_class push])
  end

  it "names only commands the client knows" do
    chain = js.show.hide.toggle.add_class("a").remove_class("a").toggle_class("a")
              .set_attribute("aria-expanded", true).remove_attribute("title").toggle_attribute("open")
              .focus.focus_first.dispatch("opened").push(:save).show_modal("#d").close_dialog

    expect(chain.ops.map(&:first)).to eq(described_class::OPS)
  end

  it "serializes to the wire form" do
    expect(js.toggle("#menu").push(:log, with: { id: 3 }).to_json)
      .to eq('[["toggle",{"to":"#menu"}],["push",{"action":"log","with":{"id":3}}]]')
  end

  describe "targets" do
    it "is the control when none is given" do
      expect(js.show.ops).to eq([["show", {}]])
    end

    it "takes a selector for the whole document" do
      expect(js.focus("#title").ops).to eq([["focus", { "to" => "#title" }]])
    end

    it "takes a selector inside the control" do
      expect(js.show({ inner: ".menu" }).ops).to eq([["show", { "to" => { "inner" => ".menu" } }]])
    end

    it "takes a selector for the nearest ancestor" do
      expect(js.add_class("on", to: { closest: "li" }).ops)
        .to eq([["add_class", { "names" => ["on"], "to" => { "closest" => "li" } }]])
    end

    it "refuses anything else" do
      expect { js.show(:menu) }.to raise_error(ArgumentError, /must be a selector/)
      expect { js.show({ within: "li" }) }.to raise_error(ArgumentError, /must be a selector/)
      expect { js.show("  ") }.to raise_error(ArgumentError, /non-empty string/)
      expect { js.show({ inner: nil }) }.to raise_error(ArgumentError, /non-empty string/)
    end
  end

  describe "classes" do
    it "splits a string and takes an array" do
      expect(js.add_class("a b").ops.dig(0, 1, "names")).to eq(%w[a b])
      expect(js.toggle_class(%i[a b]).ops.dig(0, 1, "names")).to eq(%w[a b])
    end

    it "needs a name" do
      expect { js.remove_class("") }.to raise_error(ArgumentError, /at least one class name/)
    end
  end

  describe "attributes" do
    it "writes the value as text" do
      expect(js.set_attribute("aria-expanded", true).ops)
        .to eq([["set_attribute", { "name" => "aria-expanded", "value" => "true" }]])
    end

    it "toggles presence with an empty value by default" do
      expect(js.toggle_attribute(:open).ops).to eq([["toggle_attribute", { "name" => "open", "value" => "" }]])
    end

    %w[onclick ONLOAD style srcdoc data-hibiki-on data-controller data-action].each do |name|
      it "refuses #{name}" do
        expect { js.set_attribute(name, "x") }.to raise_error(ArgumentError, /not one a command may write/)
        expect { js.remove_attribute(name) }.to raise_error(ArgumentError, /not one a command may write/)
      end
    end

    it "refuses a name that is not an attribute name" do
      expect { js.set_attribute("a b", "x") }.to raise_error(ArgumentError, /not one a command may write/)
    end
  end

  describe "dispatch" do
    it "bubbles unless told not to, and carries a detail" do
      expect(js.dispatch("cart:opened", detail: { id: 1 }).ops)
        .to eq([["dispatch", { "name" => "cart:opened", "detail" => { id: 1 } }]])
      expect(js.dispatch("ping", bubbles: false).ops).to eq([["dispatch", { "name" => "ping", "bubbles" => false }]])
    end

    it "refuses a name with a space" do
      expect { js.dispatch("a b") }.to raise_error(ArgumentError, /dispatched event/)
    end
  end

  describe "push" do
    it "validates the action like on does" do
      expect { js.push("a->b") }.to raise_error(ArgumentError, /event or action name/)
    end

    it "says whether a list has one" do
      expect(js.hide.push?).to be(false)
      expect(js.hide.push(:cancel).push?).to be(true)
    end
  end

  describe "dialogs" do
    it "needs a target to open one" do
      expect { js.show_modal(nil) }.to raise_error(ArgumentError, /show_modal needs a target/)
    end

    it "closes the control's own dialog when given none" do
      expect(js.close_dialog.ops).to eq([["close_dialog", {}]])
    end
  end
end
