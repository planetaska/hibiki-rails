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
    let(:stylesheet) { Hibiki::Rails::Generators::ScaffoldTransportStylesheet::STYLESHEET }

    # An asset, not a view. It carries no model knowledge — every rule keys on
    # an attribute the client stamps — so it is one file per APP, which is also
    # what keeps a two-resource app from carrying two identical copies of it.
    it "ships with every variant, as one asset and no view" do
      Hibiki::Rails::Generators::CssVariant::NAMES.each do |variant|
        FileUtils.rm_rf(Dir[File.join(@destination, "app")])
        generate(["--css=#{variant}"])

        expect(exists?(stylesheet)).to be(true)
        expect(Dir[File.join(@destination, "app/views/**/*busy*")]).to be_empty
        expect(generated("app/views/books/index.html.erb")).not_to include("busy\"")
      end
    end

    # The deduplication claim, and the whole reason this stopped being a view:
    # two resources, one stylesheet. A second scaffold writes byte-identical
    # content, so Thor reports `identical` and never prompts — and a variant
    # change, which is the one case the content really differs, gets Thor's
    # conflict prompt, the same granularity every other file here gets.
    it "is one file for the whole app, however many resources are scaffolded" do
      generate
      run_generator(described_class, %w[Item], destination: @destination)

      expect(Dir[File.join(@destination, "app/assets/stylesheets/*.css")].map { File.basename(it) })
        .to contain_exactly("hibiki_busy.css")
      expect(Dir[File.join(@destination, "app/views/**/*busy*")]).to be_empty
    end

    # A rule, not a class string. The token map names the spinner's LOOK; it
    # cannot express "visible only while an ancestor carries this attribute",
    # which is what every one of these recipes actually needs — so the rules
    # are emitted once, identically, for all three variants.
    it "carries the same rules in every variant, and only the look differs" do
      rules = Hibiki::Rails::Generators::CssVariant::NAMES.to_h do |variant|
        FileUtils.rm_rf(Dir[File.join(@destination, "app")])
        generate(["--css=#{variant}"])
        [variant, generated(stylesheet)]
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

      expect(generated(stylesheet)).not_to match(/^\s*\.hbk-spinner\s*\{[^}]*display/m)
    end

    # These rules set `display` on elements that also carry utility classes, and
    # Tailwind 4 layers its utilities. Unlayered wins over layered whatever the
    # link order — wrap this file in a layer and every control spinner is
    # permanently visible, in the styled variants only.
    it "declares no cascade layer" do
      generate

      expect(generated(stylesheet)).not_to match(/^\s*@layer\b/)
    end
  end

  # "The main stylesheet" is not one thing, and the wrong guess fails silently:
  # the file is on disk, nothing links it, and every indicator is invisible.
  describe "getting it onto the page" do
    def write(path, body)
      full = File.join(@destination, path)
      FileUtils.mkdir_p(File.dirname(full))
      File.write(full, body)
    end

    def layout(link) = write("app/views/layouts/application.html.erb", <<~ERB)
      <html><head>
        <%= stylesheet_link_tag #{link}, "data-turbo-track": "reload" %>
      </head><body><%= yield %></body></html>
    ERB

    it "imports from a cssbundling entry stylesheet" do
      write("app/assets/stylesheets/application.tailwind.css", %(@import "tailwindcss";\n))
      layout(%("application"))

      expect(generate).to include("imported from your entry stylesheet")
      # The leading ./ is load-bearing: Tailwind 4's CLI resolves imports like
      # a bundler, so a bare specifier is looked up as a package and the build
      # fails even though the file is right there.
      expect(generated("app/assets/stylesheets/application.tailwind.css"))
        .to include(%(@import "./hibiki_busy.css";))
    end

    # CSS wants every @import above any other statement, so landing below a
    # @plugin line would emit an invalid entry. Directly under Tailwind's own
    # import, and any hand-added lines below are the user's to order.
    it "lands directly below Tailwind's import, above any @plugin line" do
      write("app/assets/stylesheets/application.tailwind.css",
            %(@import "tailwindcss";\n@plugin "daisyui";\n))
      layout(%("application"))

      generate

      expect(generated("app/assets/stylesheets/application.tailwind.css"))
        .to eq(%(@import "tailwindcss";\n@import "./hibiki_busy.css";\n@plugin "daisyui";\n))
    end

    # tailwindcss-rails keeps its entry in a directory of its own, so the
    # import has to climb out of it to reach app/assets/stylesheets.
    it "imports from a tailwindcss-rails entry stylesheet, path adjusted" do
      write("app/assets/tailwind/application.css", %(@import "tailwindcss";\n))
      layout(%("application"))

      generate

      expect(generated("app/assets/tailwind/application.css"))
        .to include(%(@import "../stylesheets/hibiki_busy.css";))
    end

    # Propshaft's bulk helper already links every css file under app/assets, so
    # dropping the file in is the whole of the wiring.
    it "leaves a layout alone when it links stylesheets in bulk" do
      layout(":app")

      generate

      expect(generated("app/views/layouts/application.html.erb")).not_to include("hibiki_busy")
    end

    # The stock propshaft shape, and the one that needs the layout edit:
    # propshaft's only css compiler rewrites url(...), never @import, so an
    # import appended to application.css resolves to an undigested path.
    it "links from the layout when nothing else will carry it" do
      layout(%("application"))

      expect(generate).to include("linked from app/views/layouts/application.html.erb")
      expect(generated("app/views/layouts/application.html.erb"))
        .to include(%(stylesheet_link_tag "hibiki_busy"))
    end

    # The idempotence probe must use the entry's OWN import line: this entry's
    # spelling climbs out of the directory, and probing for the "./" one
    # re-appended the import on every re-run.
    it "imports into the path-adjusted entry at most once across two resources" do
      write("app/assets/tailwind/application.css", %(@import "tailwindcss";\n))
      layout(%("application"))
      generate
      run_generator(described_class, %w[Item], destination: @destination)

      expect(generated("app/assets/tailwind/application.css").scan("hibiki_busy").size).to eq(1)
    end

    it "links the layout at most once across two resources" do
      layout(%("application"))
      generate
      run_generator(described_class, %w[Item], destination: @destination)

      expect(generated("app/views/layouts/application.html.erb").scan("hibiki_busy").size).to eq(1)
    end

    # A generator never deletes, so an app scaffolded before 0.5.0 keeps the
    # old partial on disk. Inert rather than broken, which is exactly why
    # nothing else would ever mention it.
    it "names the stale _busy partial an older scaffold left behind" do
      write("app/views/books/_busy.html.erb", "<style></style>\n")

      expect(generate).to include("app/views/books/_busy.html.erb is left over")
    end

    it "says nothing about a partial that was never there" do
      expect(generate).not_to include("left over")
    end

    # Nothing to edit is not nothing to say: the file is inert until linked.
    it "prints the exact line to paste when it cannot wire anything" do
      output = generate

      expect(output).to include("nothing links it")
      expect(output).to include(%(stylesheet_link_tag "hibiki_busy"))
      expect(output).to include(%(@import "./hibiki_busy.css";))
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

        expect(generated("app/views/shared/_pagination.html.erb")).not_to include("hbk-")
      end
    end
  end

  # Exit criterion 5: if pending state had needed a Ruby option, the primitive
  # would have been the wrong one.
  it "leaves the Ruby helper surface untouched, in either view layer" do
    [[], %w[--phlex]].each do |flags|
      FileUtils.rm_rf(Dir[File.join(@destination, "app")])
      generate(flags)

      generated_views(@destination).each do |view|
        expect(File.read(view)).not_to match(/\bon\(.*busy:/)
        expect(File.read(view)).not_to match(/hibiki_island\(.*busy:/)
      end
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
