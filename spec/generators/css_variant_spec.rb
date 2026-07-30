# frozen_string_literal: true

require "rails_helper"
require "tmpdir"
require "generators/hibiki/rails/css_variant"

RSpec.describe Hibiki::Rails::Generators::CssVariant do
  around do |example|
    Dir.mktmpdir do |dir|
      @root = dir
      example.run
    end
  end

  def write(path, content)
    full = File.join(@root, path)
    FileUtils.mkdir_p(File.dirname(full))
    File.write(full, content)
  end

  describe ".detect" do
    it "prefers daisyui, which appears in package.json" do
      write("package.json", %({"dependencies":{"daisyui":"^5.7.0","tailwindcss":"^4.3.3"}}))

      expect(described_class.detect(@root)).to eq(:daisyui)
    end

    it "finds daisyui in the entry stylesheet when package.json does not name it" do
      # DaisyUI 5 is a CSS-only plugin under Tailwind 4, so an app can pull it
      # in through the stylesheet alone.
      write("app/assets/stylesheets/application.tailwind.css", %(@import "tailwindcss";\n@plugin "daisyui";))

      expect(described_class.detect(@root)).to eq(:daisyui)
    end

    it "falls back to tailwind" do
      write("package.json", %({"dependencies":{"tailwindcss":"^4.3.3"}}))

      expect(described_class.detect(@root)).to eq(:tailwind)
    end

    it "accepts tailwindcss-rails in the Gemfile" do
      write("Gemfile", %(gem "tailwindcss-rails"\n))

      expect(described_class.detect(@root)).to eq(:tailwind)
    end

    it "does not read cssbundling-rails as tailwind" do
      # cssbundling bundles Bootstrap and Sass just as happily; guessing
      # tailwind from it would restyle an app that has no Tailwind at all.
      write("Gemfile", %(gem "cssbundling-rails"\n))

      expect(described_class.detect(@root)).to eq(:none)
    end

    it "detects none in a bare app" do
      expect(described_class.detect(@root)).to eq(:none)
    end
  end

  describe ".token" do
    it "returns the variant's string" do
      expect(described_class.token(:daisyui, :btn_primary)).to eq("btn btn-primary")
      expect(described_class.token(:tailwind, :btn_primary)).to eq(described_class::PRIMARY_BUTTON)
    end

    it "returns nil for every token under none, so the attribute is omitted" do
      described_class::DAISYUI.each_key do |name|
        expect(described_class.token(:none, name)).to be_nil
      end
    end

    it "inherits layout utilities into the tailwind variant unchanged" do
      # DaisyUI is a plugin over Tailwind; only component tokens are
      # overridden, which is what makes TAILWIND a merge rather than a fork.
      %i[page heading actions_bar list row_form checkbox_wrap form_actions].each do |name|
        expect(described_class.token(:tailwind, name)).to eq(described_class.token(:daisyui, name))
      end
    end

    it "raises on an unknown token under every variant" do
      # Under --css=none a typo would otherwise be indistinguishable from a
      # token that is meant to be absent.
      described_class::VARIANTS.each_key do |variant|
        expect { described_class.token(variant, :btn_gost) }
          .to raise_error(ArgumentError, /unknown css token/)
      end
    end
  end

  it "defines every token in all three variants" do
    expect(described_class::TAILWIND.keys).to match_array(described_class::DAISYUI.keys)
    expect(described_class::NAMES).to eq(%w[daisyui tailwind none])
  end
end
