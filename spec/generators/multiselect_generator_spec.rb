# frozen_string_literal: true

require "rails_helper"
require "support/generator_harness"
require_relative "../support/scaffold_models"

RSpec.describe Hibiki::Rails::Generators::MultiselectGenerator do
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

  def write(path, content)
    full = File.join(@destination, path)
    FileUtils.mkdir_p(File.dirname(full))
    File.write(full, content)
  end

  def scaffold(args = ["Item", "--css=daisyui"])
    run_generator(Hibiki::Rails::Generators::ScaffoldControllerGenerator, args,
                  destination: @destination)
  end

  def generate(args)
    run_generator(described_class, args, destination: @destination)
  end

  def seed_models
    write("app/models/item.rb", <<~RUBY)
      class Item < ApplicationRecord
        belongs_to :shelf
      end
    RUBY
    write("app/models/fitting.rb", <<~RUBY)
      class Fitting < ApplicationRecord
        belongs_to :item
        belongs_to :part
      end
    RUBY
  end

  describe "with an existing join model" do
    before do
      scaffold
      seed_models
      generate(%w[Item Part Fitting --css=daisyui])
    end

    it "emits the concern as a prepend-wrapper around the channel's lifecycle" do
      concern = generated("app/channels/concerns/items_channel/parts_multiselect.rb")

      expect(concern).to include("module ItemsChannel::PartsMultiselect")
      expect(concern).to include("included { prepend GraphHooks }")
      expect(concern).to include("OPTIONS_LIMIT = 50")
      expect(concern).to include("rows = scope.limit(OPTIONS_LIMIT + 1).pluck(:name, :id)")
      expect(concern).to include("def toggle_part(data)")
      expect(concern).to include("def search_parts(data)")
      # The wrapped hooks call super — replacing them would sever the channel.
      expect(concern.scan(/^\s*(?:locals = )?super$/).size).to eq(3)
    end

    it "gives the channel exactly one new line — the include" do
      channel = generated("app/channels/items_channel.rb")

      expect(channel).to include("  include Hibiki::Rails::Channel\n  include PartsMultiselect\n")
    end

    it "adds the ids signal to the form, after reactive_attributes" do
      form = generated("app/forms/item_form.rb")

      expect(form).to match(/reactive_attributes.*^  reactive_association :parts$/m)
      expect(form.index("reactive_association :parts")).to be < form.index("derived(:live_errors)")
    end

    it "injects the has_many pair into the owner and touch: into the join" do
      expect(generated("app/models/item.rb")).to include("has_many :fittings, dependent: :destroy")
      expect(generated("app/models/item.rb")).to include("has_many :parts, through: :fittings")
      expect(generated("app/models/fitting.rb")).to include("belongs_to :item, touch: true")
    end

    it "emits the dropdown partial riding the extras hash" do
      partial = generated("app/views/items/_parts_multiselect.html.erb")

      expect(partial).to include("<%# locals: (form:, dom:, extras: {}) -%>")
      expect(partial).to include("extras.fetch(:parts_multiselect, { options: [] })")
      # The selection never rides the submit payload — the checkbox is named
      # "checked", not part_ids[]. (The comment may NAME the rejected form;
      # no tag may carry it.)
      expect(partial).to include(%(check_box_tag "checked"))
      expect(partial).not_to include(%("part_ids[]"))
      expect(partial).to include("**on(:toggle_part, event: :change, with: { id: id })")
      expect(partial).to include("**on(:search_parts, event: :input)")
    end

    it "renders the partial from the row form and the labels from the row" do
      row_form = generated("app/views/items/_item_form.html.erb")
      row = generated("app/views/items/_item.html.erb")

      # EXACTLY once, and immediately before the fieldset's close: Thor's
      # insert_into_file replaces every anchor match, and a bare "  </div>"
      # anchor matched the form-actions close AND (as a substring) the
      # boolean field's "    </div>" — two extra dropdowns.
      expect(row_form.scan(%(<%= render "items/parts_multiselect", form: form, dom: dom, extras: extras %>)).size)
        .to eq(1)
      expect(row_form).to include(%(extras: extras %>\n  </div>))
      expect(row.scan('<%= item.parts.map(&:name).join(", ").presence || "—" %>').size).to eq(1)
    end

    it "extends both strict_loading preloads" do
      expect(generated("app/models/item_query.rb"))
        .to include("matched_scope.includes(:shelf, :parts)")
      expect(generated("app/channels/item_channel.rb"))
        .to include("Item.includes(:shelf, :parts).strict_loading")
    end

    it "generates no migration and emits sources that compile" do
      expect(Dir[File.join(@destination, "db/migrate/*.rb")]).to be_empty
      expect_valid_generated_sources(@destination)
    end

    it "is idempotent — a re-run changes nothing" do
      before_state = Dir[File.join(@destination, "app/**/*")].to_h { [it, (File.read(it) if File.file?(it))] }
      generate(%w[Item Part Fitting --css=daisyui])

      after_state = Dir[File.join(@destination, "app/**/*")].to_h { [it, (File.read(it) if File.file?(it))] }
      expect(after_state).to eq(before_state)
    end
  end

  describe "with the association already declared" do
    before do
      scaffold
      write("app/models/item.rb", <<~RUBY)
        class Item < ApplicationRecord
          belongs_to :shelf
          has_many :item_stickers, dependent: :destroy
          has_many :stickers, through: :item_stickers
        end
      RUBY
    end

    it "needs no join argument and leaves the owner model alone" do
      generate(%w[Item Sticker --css=daisyui])

      expect(exists?("app/channels/concerns/items_channel/stickers_multiselect.rb")).to be(true)
      expect(generated("app/models/item.rb")).not_to include("has_many :stickers, through: :item_stickers\n  has_many")
    end

    it "falls back to the first string column for the label" do
      output = generate(%w[Item Sticker --css=daisyui])

      expect(output).to include("using Sticker#caption as the option label")
      expect(generated("app/channels/concerns/items_channel/stickers_multiselect.rb"))
        .to include("pluck(:caption, :id)")
    end
  end

  describe "generating the join model" do
    before do
      scaffold
      seed_models
      @output = generate(%w[Item Part Assembly --css=daisyui])
    end

    it "emits the model with touch: and the paired-unique migration" do
      expect(generated("app/models/assembly.rb")).to include("belongs_to :item, touch: true")
      expect(generated("app/models/assembly.rb")).to include("belongs_to :part")

      migration = Dir[File.join(@destination, "db/migrate/*_create_assemblies.rb")].sole
      expect(File.read(migration)).to include("t.references :item, null: false, foreign_key: true")
      expect(File.read(migration)).to include("add_index :assemblies, %i[item_id part_id], unique: true")
    end

    it "wires the owner through the new join and says to migrate" do
      expect(generated("app/models/item.rb")).to include("has_many :assemblies, dependent: :destroy")
      expect(generated("app/models/item.rb")).to include("has_many :parts, through: :assemblies")
      expect(@output).to include("run bin/rails db:migrate")
    end
  end

  describe "--skip-search" do
    before do
      scaffold
      seed_models
      generate(%w[Item Part Fitting --skip-search --css=daisyui])
    end

    it "drops the filter, the actions behind it, and the limit that would strand options" do
      concern = generated("app/channels/concerns/items_channel/parts_multiselect.rb")
      partial = generated("app/views/items/_parts_multiselect.html.erb")

      expect(concern).not_to include("OPTIONS_LIMIT")
      expect(concern).not_to include("search_parts")
      expect(partial).not_to include("search_field_tag")
      expect(partial).not_to include("type to narrow")
      expect_valid_generated_sources(@destination)
    end
  end

  describe "--phlex" do
    before do
      scaffold(%w[Item --phlex --css=daisyui])
      seed_models
      generate(%w[Item Part Fitting --css=daisyui])
    end

    it "detects the view layer from the scaffold and emits a component" do
      component = generated("app/views/items/parts_multiselect.rb")

      expect(component).to include("class Views::Items::PartsMultiselect < Views::Base")
      expect(component).to include("def initialize(form:, dom:, extras: {})")
      expect(generated("app/views/items/row_form.rb"))
        .to include("render Views::Items::PartsMultiselect.new(form: @form, dom: @dom, extras: @extras)")
      expect(generated("app/views/items/row.rb")).to include("plain(@item.parts.map(&:name)")
    end

    it "emits sources that compile and resolve under Zeitwerk" do
      expect_valid_generated_sources(@destination)
      expect_zeitwerk_resolvable_views(@destination)
    end
  end

  describe "a pre-extras scaffold" do
    before do
      scaffold
      seed_models
      # Strip the 0.7.0 extension point back out, the shape 0.6.0 emitted.
      %w[_list.html.erb _item.html.erb _item_form.html.erb].each do |basename|
        path = File.join(@destination, "app/views/items", basename)
        File.write(path, File.read(path).gsub(", extras: {}", "").gsub(", extras: extras", ""))
      end
      @output = generate(%w[Item Part Fitting --css=daisyui])
    end

    it "threads extras back through the partial chain and says so" do
      expect(@output).to include("pre-0.7 scaffold")
      expect(generated("app/views/items/_list.html.erb")).to include("extras: {}")
      expect(generated("app/views/items/_item.html.erb")).to include("form: form, extras: extras")
      expect(generated("app/views/items/_item_form.html.erb")).to include("extras: {}")
      expect_valid_generated_sources(@destination)
    end
  end

  it "emits sources that compile in every css variant, in both view layers" do
    Hibiki::Rails::Generators::CssVariant::NAMES.each do |variant|
      [[], %w[--phlex]].each do |layer|
        Dir.mktmpdir do |dir|
          @destination = dir
          write("config/routes.rb", "Rails.application.routes.draw do\nend\n")
          scaffold(["Item", *layer, "--css=#{variant}"])
          seed_models
          generate(["Item", "Part", "Fitting", *layer, "--css=#{variant}"])

          expect_valid_generated_sources(dir)
        end
      end
    end
  end

  describe "preflight" do
    it "refuses an owner that is not hibiki-scaffolded" do
      expect(generate(%w[Item Part Fitting])).to include("is not a hibiki:rails scaffold")
    end

    it "refuses a target with no model" do
      scaffold
      expect(generate(%w[Item Widget])).to include("No model Widget")
    end

    it "requires the join name when the association is undeclared" do
      scaffold
      expect(generate(%w[Item Part])).to include("name the join model")
    end
  end
end
