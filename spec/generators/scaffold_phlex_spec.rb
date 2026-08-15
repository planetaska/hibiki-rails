# frozen_string_literal: true

require "rails_helper"
require "support/generator_harness"
require_relative "../support/scaffold_models"

# The --phlex view layer.
#
# Its own file rather than a describe block in the scaffold_controller spec,
# for the same reason the loading state has one: this is a second tree of
# templates, and the assertions that matter are about the SEAM between them —
# what changes, what must not, and what the two trees have to keep agreeing on.
RSpec.describe Hibiki::Rails::Generators::ScaffoldControllerGenerator, "--phlex" do
  include GeneratorHarness

  around do |example|
    Dir.mktmpdir do |dir|
      @destination = dir
      FileUtils.mkdir_p(File.join(dir, "config"))
      File.write(File.join(dir, "config/routes.rb"), "Rails.application.routes.draw do\nend\n")
      example.run
    end
  end

  def generated(path) = File.read(File.join(@destination, path))
  def exists?(path) = File.exist?(File.join(@destination, path))

  def generate(args = [], name: "Item")
    run_generator(described_class, [name, *args], destination: @destination)
  end

  # phlex:install's own artifacts. Generated components inherit Views::Base and
  # are reached by constant, so both have to be there or nothing resolves.
  def phlex_installed
    FileUtils.mkdir_p(File.join(@destination, "app/views"))
    File.write(File.join(@destination, "app/views/base.rb"), "class Views::Base < Components::Base\nend\n")
    FileUtils.mkdir_p(File.join(@destination, "config/initializers"))
    File.write(File.join(@destination, "config/initializers/phlex.rb"), <<~RUBY)
      Rails.autoloaders.main.push_dir("#{@destination}/app/views", namespace: Views)
    RUBY
  end

  describe "the wiring probes" do
    # Warn, never fail: the scaffold may legitimately come before
    # `bundle add phlex-rails`, and writing nothing would leave the user with
    # no output to fix.
    it "warns when phlex-rails is not in the bundle, and still writes the files" do
      output = generate(%w[--phlex])

      expect(output).to include("phlex-rails is not in this bundle")
      expect(exists?("app/channels/items_channel.rb")).to be(true)
    end

    # The one that actually bites. A successful require proves the GEM is
    # present and proves nothing about this app — without base.rb and the
    # autoloader mapping, every page raises NameError at its first request.
    it "warns when phlex:install has not run" do
      expect(generate(%w[--phlex])).to include("phlex:install has not run")
    end

    it "says nothing about phlex:install once both artifacts are there" do
      phlex_installed

      expect(generate(%w[--phlex])).not_to include("phlex:install has not run")
    end

    # An initializer that pushes app/views without the Views namespace is the
    # half-configured case, and it fails exactly the same way.
    it "is not satisfied by an initializer that does not name the namespace" do
      phlex_installed
      File.write(File.join(@destination, "config/initializers/phlex.rb"), "# nothing\n")

      expect(generate(%w[--phlex])).to include("phlex:install has not run")
    end

    it "stays quiet about all of it without the flag" do
      output = generate

      expect(output).not_to include("phlex-rails is not in this bundle")
      expect(output).not_to include("phlex:install has not run")
    end

    # A generator never deletes, so an overlay run leaves the ERB templates on
    # disk — dead, because the controller now names components, and therefore
    # something nothing else would ever mention.
    it "names the ERB templates an overlay run leaves behind" do
      generate
      output = generate(%w[--phlex --force])

      expect(output).to include("still holds the ERB templates a previous run wrote")
      expect(output).to include("index.html.erb")
    end
  end

  describe "what it emits" do
    before { generate(%w[--phlex]) }

    # phlex-rails' own convention, which its install generator autoloads:
    # app/views/items/row_form.rb defines Views::Items::RowForm. No leading
    # underscore, no .html.erb, no _row rename — all three are Rails PARTIAL
    # conventions, and a component is reached by constant.
    it "writes one component per view, at the path Zeitwerk resolves" do
      expect(Dir[File.join(@destination, "app/views/items/*")].map { File.basename(it) })
        .to contain_exactly("index.rb", "show.rb", "new.rb", "edit.rb", "form.rb", "list.rb",
                            "row.rb", "row_form.rb", "controls.rb")
      # The app-wide components live under shared/, once per app.
      expect(Dir[File.join(@destination, "app/views/shared/*")].map { File.basename(it) })
        .to contain_exactly("field_error.rb", "form_errors.rb", "pagination.rb")
      expect_zeitwerk_resolvable_views(@destination)
    end

    it "writes no ERB at all" do
      expect(Dir[File.join(@destination, "app/views/**/*.erb")]).to be_empty
    end

    # The summary derives the resource name from the record at render time, so
    # one shared component serves every scaffold.
    it "renders the form's error summary from the shared component" do
      expect(generated("app/views/items/form.rb"))
        .to include("render Views::Shared::FormErrors.new(record: @item)")
      expect(generated("app/views/shared/form_errors.rb"))
        .to include("@record.model_name.human.downcase")
    end

    # A Phlex component cannot see a controller's ivars, so every site has to
    # name it. SIX, not four: create and update re-render on validation
    # failure, and those are the two easiest to miss because they name a
    # template rather than a partial.
    it "renders explicitly at all six controller sites" do
      controller = generated("app/controllers/items_controller.rb")

      expect(controller.scan("render Views::Items::").size).to eq(6)
      expect(controller).to include("render Views::Items::Index.new(item_query: @item_query)")
      expect(controller).to include("render Views::Items::New.new(item: @item, shelves: @shelves), " \
                                    "status: :unprocessable_content")
    end

    # layout: false is not optional. turbo-rails renders a broadcast through
    # ApplicationController.render, where a partial: never takes a layout and a
    # renderable: does — so without it every broadcast ships the whole page
    # shell wrapped around the fragment. Measured on a generated app: 885 bytes
    # against 138, and it does NOT raise, because the extra wrapper is parsed
    # away inside Turbo's <template> and idiomorph still finds its id.
    it "broadcasts a renderable with the layout off, from both channels" do
      expect(generated("app/channels/items_channel.rb"))
        .to include("renderable: Views::Items::List.new(**list_locals), layout: false")
      expect(generated("app/channels/item_channel.rb"))
        .to include("renderable: Views::Items::Row.new(item: row, actions: false)")
      expect(generated("app/channels/item_channel.rb")).to include("layout: false")
    end

    # The keyword list IS the broadcast's contract — the channel builds the
    # component with .new(**list_locals) — and Ruby enforces it, which is the
    # upgrade over a strict-locals header.
    it "declares every list local as a keyword, with its default" do
      expect(generated("app/views/items/list.rb"))
        .to include("def initialize(items:, page: 1, page_count: 1, remaining: 0, editing_id: nil, " \
                    "form: nil,\n                 creating: false, new_form: nil, url_params: {}, " \
                    "shelf_options: [], extras: {})")
    end

    # The 0.8.0 fallback surface, mirrored: the destroy form rides the
    # phlex-rails ButtonTo adapter (button_to is a Rails helper, so `false`
    # stays a boolean here — the drop-false rule is Phlex-native attributes
    # only), the controls are one GET form, and the create form re-aims the
    # shared row form at the *_new actions.
    it "mirrors the fallback and inline-create surface" do
      row = generated("app/views/items/row.rb")
      expect(row).to include("include Phlex::Rails::Helpers::ButtonTo")
      expect(row).to include('button_to "Destroy", item_path(@item.id), method: :delete,')
      expect(row).to include("**on(:edit, with: { id: @item.id }, fallback: true)")

      controls = generated("app/views/items/controls.rb")
      expect(controls).to include('form(action: items_path, method: "get",')
      expect(controls).to include("**on(:search, event: :submit, fallback: true, reset: false)")

      list = generated("app/views/items/list.rb")
      expect(list).to include("create_form if @creating")
      expect(list).to include("form: @new_form")
      expect(list).to include("save_action: :create")
      expect(list).to include("url: page_url")

      row_form = generated("app/views/items/row_form.rb")
      expect(row_form).to include("**on(@save_action, event: :submit, reset: false)")
      expect(row_form).to include("**on(@cancel_action, with: @cancel_with)")

      pagination = generated("app/views/shared/pagination.rb")
      expect(pagination).to include(%(def href(n) = @url ? "\#{@url.(n)}\#{@anchor}" : @anchor))
      expect(pagination).to include("fallback: @url ? true : nil")

      index = generated("app/views/items/index.rb")
      expect(index).to include("params: @item_query.url_params.presence")
      expect(index).to include("**on(:new_form, fallback: true)")
    end

    # phlex-rails' options_for_select outputs directly and returns an object
    # that raises when handed to another helper. Both select sites take a block.
    it "never passes options_for_select as an argument" do
      generated_views(@destination).each do |view|
        expect(File.read(view)).not_to match(/\w+\(.*options_for_select\(/)
      end
    end

    # Phlex renders String, Symbol, Integer and Float and RAISES on anything
    # else, where ERB's <%= %> just called to_s.
    it "adds to_s to the columns Phlex cannot render bare, and to no others" do
      row = generated("app/views/items/row.rb")

      expect(row).to include("plain @item.due_on.to_s")
      expect(row).to include("plain @item.title")
      expect(row).not_to include("plain @item.title.to_s")
      # A belongs_to prints the association's label — a string, so no to_s.
      expect(row).to include("plain @item.shelf&.name")
    end

    # Phlex emits NO whitespace between siblings, where ERB's newlines collapse
    # to one — so without this the label runs into its value and the page
    # controls run into each other.
    it "spaces text and inline controls that would otherwise touch" do
      expect(generated("app/views/items/row.rb")).to include("whitespace")
      expect(generated("app/views/shared/pagination.rb")).to include("whitespace")
    end

    # Every fact still comes from the model; only the markup changed.
    it "leaves the query and the form untouched by the flag" do
      erb = Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "config"))
        File.write(File.join(dir, "config/routes.rb"), "Rails.application.routes.draw do\nend\n")
        run_generator(described_class, %w[Item], destination: dir)
        %w[app/models/item_query.rb app/forms/item_form.rb]
          .to_h { [it, File.read(File.join(dir, it))] }
      end

      erb.each { |path, source| expect(generated(path)).to eq(source) }
    end
  end

  describe "the options it composes with" do
    it "--css=none omits the class keyword rather than emitting class: nil" do
      generate(%w[--phlex --css=none])

      expect(generated("app/views/shared/field_error.rb")).to include("p { @message }")
      expect(generated("app/views/shared/field_error.rb")).not_to include("class:")
      # The error summary keeps the scaffold-stock block under none.
      expect(generated("app/views/shared/form_errors.rb")).to include(%(div(style: "color: red")))
      expect(generated("app/views/shared/form_errors.rb")).not_to include("class:")
    end

    # The page control is the one component with a per-variant template. Under
    # Phlex the tailwind fork's REASON dissolves — a hoisted template local
    # becomes an ordinary constant — but it stays forked so the two trees match
    # file for file. The --css=none fork survives on its own terms: it changes a
    # tag name, which no class map can express.
    it "forks only the page control, and only `none` structurally" do
      forks = {}
      %w[daisyui tailwind none].each do |variant|
        FileUtils.rm_rf(Dir[File.join(@destination, "app")])
        generate(["--phlex", "--css=#{variant}"])
        forks[variant] = generated("app/views/shared/pagination.rb")
      end

      # A tag name, which no class map can express — the fork that survives.
      expect(forks["none"]).to include(%(strong(aria_current: "page")))
      # Two class strings, which one could — kept forked so the trees match.
      expect(forks["daisyui"]).to include("btn-active")
      expect(forks["tailwind"]).to include("ITEM_CURRENT")
      expect(forks["daisyui"]).not_to include("ITEM_CURRENT")
    end

    it "--infinite-scroll inlines the sentinel and writes no page control" do
      generate(%w[--phlex --infinite-scroll])

      expect(exists?("app/views/shared/pagination.rb")).to be(false)
      expect(generated("app/views/items/list.rb")).to include("%i[click visible]")
    end

    it "emits sources that compile, in every variant and every pagination mode" do
      [%w[--phlex], %w[--phlex --infinite-scroll], %w[--phlex --skip-pagination]].each do |mode|
        Hibiki::Rails::Generators::CssVariant::NAMES.each do |variant|
          FileUtils.rm_rf(Dir[File.join(@destination, "app")])
          generate([*mode, "--css=#{variant}"])

          expect_valid_generated_sources(@destination)
        end
      end
    end

    it "nests the namespace the same way view_dir does" do
      run_generator(described_class, %w[admin/Gadget title:string --phlex], destination: @destination)

      expect(generated("app/views/admin/gadgets/row.rb"))
        .to include("class Views::Admin::Gadgets::Row < Views::Base")
      expect_zeitwerk_resolvable_views(@destination)
    end
  end
end
