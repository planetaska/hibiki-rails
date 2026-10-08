# frozen_string_literal: true

require "spec_helper"

RSpec.describe Hibiki::Rails::Keys do
  describe ".token" do
    it "passes a named key through" do
      expect(described_class.token("keydown.esc")).to eq("keydown.esc")
    end

    it "accepts a letter and a digit" do
      expect(described_class.token("keydown.n")).to eq("keydown.n")
      expect(described_class.token("keydown.1")).to eq("keydown.1")
    end

    it "lowercases the token" do
      expect(described_class.token("keydown.Enter")).to eq("keydown.enter")
    end

    it "puts modifiers in wire order, once each" do
      expect(described_class.token("keydown.shift+meta+ctrl+ctrl+k")).to eq("keydown.ctrl+meta+shift+k")
    end

    it "keeps the window scope" do
      expect(described_class.token("keydown.ctrl+k@window")).to eq("keydown.ctrl+k@window")
    end

    it "rejects a bare keydown, pointing at input" do
      expect { described_class.token("keydown") }.to raise_error(ArgumentError, /names no key.*:input/)
      expect { described_class.token("keydown@window") }.to raise_error(ArgumentError, /names no key/)
    end

    it "rejects a key outside the list" do
      expect { described_class.token("keydown.f1") }.to raise_error(ArgumentError, /key "f1"/)
      expect { described_class.token("keydown./") }.to raise_error(ArgumentError, %r{key "/"})
    end

    it "rejects alt and any other unknown modifier" do
      expect { described_class.token("keydown.alt+s") }.to raise_error(ArgumentError, /modifier "alt"/)
    end

    it "rejects a modifier with no key after it" do
      expect { described_class.token("keydown.ctrl+") }.to raise_error(ArgumentError, /key "ctrl"/)
    end

    it "rejects shift with a digit" do
      expect { described_class.token("keydown.shift+1") }.to raise_error(ArgumentError, /shift/)
    end

    it "rejects any other event, which is how a scope on one gets named" do
      expect { described_class.token("click@window") }.to raise_error(ArgumentError, /only a keydown/)
    end

    it "rejects a scope other than window" do
      expect { described_class.token("keydown.esc@document") }.to raise_error(ArgumentError, /scope "document"/)
    end
  end
end
