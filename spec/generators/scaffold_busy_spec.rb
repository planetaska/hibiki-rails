# frozen_string_literal: true

require "rails_helper"
require "support/generator_harness"
require_relative "../support/scaffold_models"

# The loading recipes: what a generated app shows while a round trip is out.
#
# Everything here rests on one attribute pair the CLIENT stamps
# (data-hibiki-busy on the island root and on the control that fired,
# data-hibiki-state on the root), so the test that matters most is the one
# about how little markup each site needs. If a site ever needs more than
# this, the primitive is wrong.
RSpec.describe Hibiki::Rails::Generators::ScaffoldControllerGenerator, "loading state" do
  include GeneratorHarness

  around do |example|
    Dir.mktmpdir do |dir|
      @destination = dir
      FileUtils.mkdir_p(File.join(dir, "config"))
      File.write(File.join(dir, "config/routes.rb"), "Rails.application.routes.draw do\nend\n")
      example.run
    end
  end

  def book_fields = %w[author:references title:string stock:integer available:boolean]
  def generated(path) = File.read(File.join(@destination, path))
  def exists?(path) = File.exist?(File.join(@destination, path))

  def generate(args = [])
    run_generator(described_class, ["Book", *book_fields, *args], destination: @destination)
  end

  describe "the transport stylesheet" do
    it "ships with every variant and is rendered once, outside the island" do
      Hibiki::Rails::Generators::CssVariant::NAMES.each do |variant|
        FileUtils.rm_rf(Dir[File.join(@destination, "app")])
        generate(["--css=#{variant}"])

        expect(exists?("app/views/books/_busy.html.erb")).to be(true)
        index = generated("app/views/books/index.html.erb")
        expect(index).to include(%(render "books/busy"))
        # After the island's `end`, so a channel re-render can never touch it.
        expect(index.index(%(render "books/busy"))).to be > index.rindex("<% end %>")
      end
    end

    # A rule, not a class string. The token map names the spinner's LOOK; it
    # cannot express "visible only while an ancestor carries this attribute",
    # which is what every one of these recipes actually needs — so the rules
    # are emitted once, identically, for all three variants.
    it "carries the same rules in every variant, and only the look differs" do
      rules = Hibiki::Rails::Generators::CssVariant::NAMES.to_h do |variant|
        FileUtils.rm_rf(Dir[File.join(@destination, "app")])
        generate(["--css=#{variant}"])
        [variant, generated("app/views/books/_busy.html.erb")]
      end

      rules.each_value do |css|
        expect(css).to include("[data-hibiki-state][data-hibiki-busy] .hbk-island-busy")
        expect(css).to include("[data-hibiki-busy]:not([data-hibiki-state]) .hbk-control-busy")
        expect(css).to include(%([data-hibiki-state="offline"] .hbk-offline))
      end

      # Only --css=none hand-rolls the ring; the others take it from a token.
      expect(rules["none"]).to include("@keyframes hbk-rotate")
      expect(rules["daisyui"]).not_to include("@keyframes hbk-rotate")
      expect(rules["tailwind"]).not_to include("@keyframes hbk-rotate")
    end

    # A control spinner is display:none until its control is busy, so a later
    # rule declaring `display` on .hbk-spinner at equal specificity would win
    # and leave every spinner permanently on screen.
    it "never re-declares display on the bare spinner class" do
      generate(["--css=none"])

      expect(generated("app/views/books/_busy.html.erb"))
        .not_to match(/^\s*\.hbk-spinner\s*\{[^}]*display/m)
    end
  end

  describe "the five sites" do
    before { generate }

    # Never re-rendered, so a list swap cannot destroy the indicator
    # mid-flight — which is exactly what would happen inside the fragment.
    it "puts the island-level indicator in the controls partial" do
      controls = generated("app/views/books/_controls.html.erb")

      expect(controls).to include(%(class="hbk-island-busy hbk-spinner))
      expect(controls).to include(%(aria-hidden="true"))
      expect(controls).to include(%(role="status"), "hbk-offline", "hbk-stalled")
    end

    # Outside the replaced fragment for the same reason, and directly above
    # the list because the page links are anchors that jump there.
    it "puts the progress bar above the list, outside the fragment" do
      index = generated("app/views/books/index.html.erb")

      expect(index).to include(%(class="hbk-island-busy hbk-bar" aria-hidden="true"))
      expect(index.index("hbk-bar")).to be < index.index(%(render "books/list"))
      expect(generated("app/views/books/_list.html.erb")).not_to include("hbk-bar")
    end

    it "gives the inline-edit Save its own control-scoped spinner" do
      form = generated("app/views/books/_book_form.html.erb")

      expect(form).to include(%(class="hbk-control-busy hbk-spinner))
      # Inside the button, which is inside the form that fires the submit.
      expect(form).to match(/tag\.button.*do %>\s*(<%#.*?%>\s*)?<span class="hbk-control-busy/m)
    end

    # The two sites that are free: the client stamps the control it fired
    # from, so one rule in the stylesheet dims them and no markup changes.
    it "adds no markup to the destroy button or the load-more sentinel" do
      expect(generated("app/views/books/_book.html.erb")).not_to include("hbk-")

      run_generator(described_class, %w[Item --infinite-scroll], destination: @destination)
      list = generated("app/views/items/_list.html.erb")
      expect(list).to include("%i[click visible]")
      expect(list).not_to include("hbk-")
    end

    it "adds no markup to any of the three page controls" do
      Hibiki::Rails::Generators::CssVariant::NAMES.each do |variant|
        FileUtils.rm_rf(Dir[File.join(@destination, "app")])
        generate(["--css=#{variant}"])

        expect(generated("app/views/books/_pagination.html.erb")).not_to include("hbk-")
      end
    end
  end

  # Exit criterion 5: if pending state had needed a Ruby option, the primitive
  # would have been the wrong one.
  it "leaves the Ruby helper surface untouched" do
    generate

    Dir[File.join(@destination, "app/views/**/*.erb")].each do |view|
      expect(File.read(view)).not_to match(/\bon\(.*busy:/)
      expect(File.read(view)).not_to match(/hibiki_island\(.*busy:/)
    end
  end

  # Every generated view still parses — the Save button moved to a block form
  # under both css? branches, which is where an escaping slip would land.
  it "emits valid sources in every variant" do
    Hibiki::Rails::Generators::CssVariant::NAMES.each do |variant|
      FileUtils.rm_rf(Dir[File.join(@destination, "app")])
      generate(["--css=#{variant}"])

      expect_valid_generated_sources(@destination)
    end
  end
end
