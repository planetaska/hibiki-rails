# frozen_string_literal: true

require "rails_helper"
require "support/generator_harness"
require_relative "../support/scaffold_models"

RSpec.describe Hibiki::Rails::Generators::NestedGenerator do
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
    write("app/models/credit.rb", <<~RUBY)
      class Credit < ApplicationRecord
        belongs_to :item
        belongs_to :part

        validates :role, presence: true
      end
    RUBY
    write("app/models/remark.rb", <<~RUBY)
      class Remark < ApplicationRecord
        belongs_to :credit

        validates :body, presence: true
      end
    RUBY
  end

  describe "the root edge (Item Credit, ordered via the real position column)" do
    before do
      scaffold
      seed_models
      generate(%w[Item Credit --css=daisyui])
    end

    it "emits the child form without the parent fk or the position column" do
      form = generated("app/forms/credit_form.rb")

      expect(form).to include("reactive_attributes Credit, :part_id, :role")
      expect(form).not_to include(":item_id")
      expect(form).not_to include(":position")
      expect(form).to include("position is deliberately absent")
      expect(form).to include(%{part_id: ("must be selected" if part_id.blank?)})
      expect(form).to include(%{role: ("can't be blank" if role.to_s.strip.empty?)})
    end

    it "emits the fields partial with path-addressed inputs and reorder buttons" do
      partial = generated("app/views/items/_credit_fields.html.erb")

      expect(partial).to include("<%# locals: (credit:, dom:, path:, part_options: [], index: 0, count: 1) -%>")
      expect(partial).to include(%(select_tag "\#{path}/part_id"))
      expect(partial).to include("options_for_select(part_options, credit.part_id)")
      expect(partial).to include("**on(:nested_set_field, event: :change, " \
                                 'with: { dom: dom, path: path, field: "part_id" })')
      expect(partial).to include("**on(:nested_set_field, event: :input, " \
                                 'with: { dom: dom, path: path, field: "role" })')
      expect(partial).to include("**on(:nested_move, with: { dom: dom, path: path, to: index - 1 })")
      expect(partial).to include("**on(:nested_move, with: { dom: dom, path: path, to: index + 1 })")
      expect(partial).to include("**on(:nested_remove, with: { dom: dom, path: path })")
    end

    it "wires the parent model with the ordered has_many pair" do
      model = generated("app/models/item.rb")

      expect(model).to include("has_many :credits, -> { order(:position) }, dependent: :destroy, " \
                               "inverse_of: :item, index_errors: true")
      expect(model).to include("accepts_nested_attributes_for :credits, allow_destroy: true")
    end

    it "adds reactive_nested and the position stamp to the parent form" do
      form = generated("app/forms/item_form.rb")

      expect(form).to include(%(reactive_nested :credits, "CreditForm"))
      expect(form.index("reactive_nested :credits")).to be < form.index("derived(:live_errors)")
      expect(form).to include("h[:credits_attributes].reject { it[:_destroy] }")
      expect(form).to include(".each_with_index { |attrs, i| attrs[:position] = i + 1 }")
    end

    it "gives the channel the include, the edit preload and the option collection" do
      channel = generated("app/channels/items_channel.rb")

      expect(channel.scan("include Hibiki::Rails::NestedActions").size).to eq(1)
      expect(channel).to include("  include Hibiki::Rails::Channel\n  # Path-addressed actions")
      expect(channel).to include(%(record = Item.includes(:credits).find_by(id: data["id"])))
      expect(channel).to include("@part_options = Hibiki::Derived.new")
      expect(channel).to include("Part.order(:name).pluck(:name, :id)")
      expect(channel).to include("part_options: ((editing_id || @creating.value) ? @part_options.value : []),")
    end

    it "threads the options local through the partial chain" do
      list = generated("app/views/items/_list.html.erb")
      row = generated("app/views/items/_item.html.erb")
      row_form = generated("app/views/items/_item_form.html.erb")

      expect(list).to include("part_options: [], extras: {}) -%>")
      expect(list.scan("part_options: part_options, extras: extras").size).to eq(2)
      expect(row).to include("part_options: [], extras: {}) -%>")
      expect(row).to include("part_options: part_options, extras: extras")
      expect(row_form).to include("part_options: [], extras: {}) -%>")
    end

    it "injects the fieldset into the row form exactly once, between fields and actions" do
      row_form = generated("app/views/items/_item_form.html.erb")

      expect(row_form.scan(%(render "items/credit_fields")).size).to eq(1)
      expect(row_form).to include(%(path: "credits/\#{credit.nested_key}"))
      expect(row_form).to include("visible_credits = form.credits.reject(&:marked_for_destruction?)")
      expect(row_form).to include("count: visible_credits.size")
      expect(row_form).to include(%(**on(:nested_add, with: { dom: dom, path: "credits" })))
      expect(row_form.index("</fieldset>")).to be < row_form.index(%(<div class="flex gap-2 items-center">))
    end

    it "adds the fields_for fallback to the page form" do
      form = generated("app/views/items/_form.html.erb")

      expect(form).to include("<%= form.fields_for :credits do |credit_form| %>")
      expect(form).to include("<%= credit_form.collection_select :part_id, Part.order(:name), :id, :name,")
      expect(form).to include("<%= credit_form.number_field :position")
      expect(form).to include("<%= credit_form.checkbox :_destroy %>")
      expect(form).to include("Remove this credit")
    end

    it "widens params.expect with the double-array group" do
      controller = generated("app/controllers/items_controller.rb")

      expect(controller)
        .to include("{ credits_attributes: [[ :id, :part_id, :role, :position, :_destroy ]] } ])")
      expect(controller).to include("The double-array")
    end

    it "generates no migration (position already exists) and compiles" do
      expect(Dir[File.join(@destination, "db/migrate/*.rb")]).to be_empty
      expect_valid_generated_sources(@destination)
    end

    it "is idempotent — a re-run changes nothing" do
      before_state = Dir[File.join(@destination, "app/**/*")].to_h { [it, (File.read(it) if File.file?(it))] }
      generate(%w[Item Credit --css=daisyui])

      after_state = Dir[File.join(@destination, "app/**/*")].to_h { [it, (File.read(it) if File.file?(it))] }
      expect(after_state).to eq(before_state)
    end
  end

  describe "the deep edge (Credit Remark after Item Credit)" do
    before do
      scaffold
      seed_models
      generate(%w[Item Credit --css=daisyui])
      generate(%w[Credit Remark --css=daisyui])
    end

    it "emits the child form and partial into the owning resource's tree" do
      expect(generated("app/forms/remark_form.rb")).to include("reactive_attributes Remark, :body")
      expect(generated("app/views/items/_remark_fields.html.erb"))
        .to include("<%# locals: (remark:, dom:, path:, index: 0, count: 1) -%>")
    end

    it "nests the fieldset into the parent's fields partial, growing the path" do
      partial = generated("app/views/items/_credit_fields.html.erb")

      expect(partial.scan(%(render "items/remark_fields")).size).to eq(1)
      expect(partial).to include(%(path: "\#{path}/remarks/\#{remark.nested_key}"))
      expect(partial).to include(%(**on(:nested_add, with: { dom: dom, path: "\#{path}/remarks" })))
      # Inside the outer div: the fieldset close precedes the final close.
      expect(partial).to end_with("</fieldset>\n</div>\n")
    end

    it "extends the edit preload into a nested include and keeps one include line" do
      channel = generated("app/channels/items_channel.rb")

      expect(channel).to include(%(record = Item.includes({ credits: :remarks }).find_by(id: data["id"])))
      expect(channel.scan("include Hibiki::Rails::NestedActions").size).to eq(1)
    end

    it "wires the unordered has_many onto Credit and reactive_nested onto CreditForm" do
      expect(generated("app/models/credit.rb"))
        .to include("has_many :remarks, dependent: :destroy, inverse_of: :credit, index_errors: true")
      credit_form = generated("app/forms/credit_form.rb")
      expect(credit_form).to include(%(reactive_nested :remarks, "RemarkForm"))
      expect(credit_form).not_to include("def to_h")
    end

    it "nests the params.expect group inside the parent's" do
      controller = generated("app/controllers/items_controller.rb")

      expect(controller).to include("{ credits_attributes: [[ :id, :part_id, :role, :position, :_destroy,")
      expect(controller).to include("{ remarks_attributes: [[ :id, :body, :_destroy ]] } ]] } ])")
    end

    it "nests the fields_for fallback inside the parent's block" do
      form = generated("app/views/items/_form.html.erb")

      expect(form).to include("<%= credit_form.fields_for :remarks do |remark_form| %>")
      expect(form.index("fields_for :remarks")).to be > form.index("fields_for :credits")
      expect(form.index("fields_for :remarks")).to be < form.index("Remove this credit")
    end

    it "compiles and is idempotent" do
      expect_valid_generated_sources(@destination)

      before_state = Dir[File.join(@destination, "app/**/*")].to_h { [it, (File.read(it) if File.file?(it))] }
      generate(%w[Credit Remark --css=daisyui])
      after_state = Dir[File.join(@destination, "app/**/*")].to_h { [it, (File.read(it) if File.file?(it))] }
      expect(after_state).to eq(before_state)
    end
  end

  describe "--position=COLUMN on a child without that column" do
    before do
      scaffold
      seed_models
      @output = generate(%w[Item Credit --position=rank --css=daisyui])
    end

    it "generates the add_column migration and says to migrate" do
      migration = Dir[File.join(@destination, "db/migrate/*_add_rank_to_credits.rb")].sole

      expect(File.read(migration)).to include("add_column :credits, :rank, :integer")
      expect(@output).to include("run bin/rails db:migrate")
    end

    it "orders and stamps by the named column, leaving position a plain field" do
      expect(generated("app/models/item.rb")).to include("-> { order(:rank) }")
      expect(generated("app/forms/item_form.rb")).to include("attrs[:rank] = i + 1")
      expect(generated("app/forms/credit_form.rb"))
        .to include("reactive_attributes Credit, :part_id, :role, :position")
    end
  end

  describe "--skip-position" do
    before do
      scaffold
      seed_models
      generate(%w[Item Credit --skip-position --css=daisyui])
    end

    it "emits an unordered fieldset with position as a plain field" do
      expect(generated("app/models/item.rb")).not_to include("order(:position)")
      expect(generated("app/forms/item_form.rb")).not_to include("def to_h")
      expect(generated("app/views/items/_credit_fields.html.erb")).not_to include("nested_move")
      expect(generated("app/forms/credit_form.rb"))
        .to include("reactive_attributes Credit, :part_id, :role, :position")
      expect_valid_generated_sources(@destination)
    end
  end

  describe "an explicit field list" do
    it "chooses order while the schema keeps the facts" do
      scaffold
      seed_models
      generate(%w[Item Credit role:string part:references --css=daisyui])

      form = generated("app/forms/credit_form.rb")
      expect(form).to include("reactive_attributes Credit, :role, :part_id")
      expect(form).to include(%{role: ("can't be blank" if role.to_s.strip.empty?)})
    end
  end

  describe "--phlex" do
    before do
      scaffold(%w[Item --phlex --css=daisyui])
      seed_models
      generate(%w[Item Credit --css=daisyui])
    end

    it "detects the view layer and emits a fields component" do
      component = generated("app/views/items/credit_fields.rb")

      expect(component).to include("class Views::Items::CreditFields < Views::Base")
      expect(component).to include("def initialize(credit:, dom:, path:, part_options: [], index: 0, count: 1)")
      expect(component).to include(%(def dom_path = "\#{@dom}_\#{@path.tr('/', '_')}"))
      expect(component).to include("**on(:nested_move, with: { dom: @dom, path: @path, to: @index - 1 })")
    end

    it "wires the row form, the page form and the initializer threading" do
      row_form = generated("app/views/items/row_form.rb")
      page_form = generated("app/views/items/form.rb")

      expect(row_form.scan("credits_fieldset").size).to eq(2)
      expect(row_form).to include("render Views::Items::CreditFields.new(")
      expect(row_form).to include(%(path: "credits/\#{credit.nested_key}"))
      expect(page_form).to include("credits_fields(form)")
      expect(page_form).to include("form.fields_for :credits do |credit_form|")
      expect(generated("app/views/items/list.rb")).to include("part_options: [], extras: {})")
      expect(generated("app/views/items/row.rb")).to include("part_options: @part_options, extras: @extras")
    end

    it "emits sources that compile and resolve under Zeitwerk" do
      expect_valid_generated_sources(@destination)
      expect_zeitwerk_resolvable_views(@destination)
    end
  end

  it "emits sources that compile in every css variant, both view layers, both edges" do
    Hibiki::Rails::Generators::CssVariant::NAMES.each do |variant|
      [[], %w[--phlex]].each do |layer|
        Dir.mktmpdir do |dir|
          @destination = dir
          write("config/routes.rb", "Rails.application.routes.draw do\nend\n")
          scaffold(["Item", *layer, "--css=#{variant}"])
          seed_models
          generate(["Item", "Credit", *layer, "--css=#{variant}"])
          generate(["Credit", "Remark", *layer, "--css=#{variant}"])

          expect_valid_generated_sources(dir)
        end
      end
    end
  end

  describe "creating the child (Item Widget with a field list, no Widget model)" do
    def widget_migration
      Dir[File.join(@destination, "db/migrate/*_create_widgets.rb")].sole
    end

    describe "the full run" do
      before do
        scaffold
        seed_models
        @output = generate(%w[Item Widget part:references role:string position:integer --css=daisyui])
      end

      it "generates the model with the parent reference prepended, and says to migrate" do
        model = generated("app/models/widget.rb")

        expect(model).to include("belongs_to :item")
        expect(model).to include("belongs_to :part")
        expect(model.index("belongs_to :item")).to be < model.index("belongs_to :part")
        expect(@output).to include("Widget was generated — run bin/rails db:migrate")
      end

      it "generates one create-table migration carrying every column, position included" do
        migration = File.read(widget_migration)

        expect(migration).to include("t.references :item, null: false, foreign_key: true")
        expect(migration).to include("t.string :role")
        expect(migration).to include("t.integer :position")
        expect(Dir[File.join(@destination, "db/migrate/*.rb")].size).to eq(1)
      end

      it "wires everything off the argument list alone" do
        expect(generated("app/forms/widget_form.rb"))
          .to include("reactive_attributes Widget, :part_id, :role")
        expect(generated("app/models/item.rb"))
          .to include("has_many :widgets, -> { order(:position) }, dependent: :destroy, " \
                      "inverse_of: :item, index_errors: true")
        expect(generated("app/controllers/items_controller.rb"))
          .to include("{ widgets_attributes: [[ :id, :part_id, :role, :position, :_destroy ]] } ])")
        expect(generated("app/views/items/_widget_fields.html.erb")).to include("nested_move")
        expect(generated("app/channels/items_channel.rb")).to include("Part.order(:name).pluck(:name, :id)")
        expect_valid_generated_sources(@destination)
      end

      it "refuses a re-run before the migration ran, changing nothing" do
        before_state = Dir[File.join(@destination, "{app,db}/**/*")]
                       .to_h { [it, (File.read(it) if File.file?(it))] }
        output = generate(%w[Item Widget part:references role:string position:integer --css=daisyui])

        expect(output).to include("Widget has no table yet. Run bin/rails db:migrate first.")
        after_state = Dir[File.join(@destination, "{app,db}/**/*")]
                      .to_h { [it, (File.read(it) if File.file?(it))] }
        expect(after_state).to eq(before_state)
      end
    end

    it "adds no position column unless the field list carries one" do
      scaffold
      seed_models
      generate(%w[Item Widget role:string --css=daisyui])

      expect(File.read(widget_migration)).not_to include(":position")
      expect(generated("app/models/item.rb")).to include("has_many :widgets, dependent: :destroy")
      expect(generated("app/views/items/_widget_fields.html.erb")).not_to include("nested_move")
      expect(generated("app/forms/item_form.rb")).not_to include("def to_h")
    end

    it "appends the --position column to the create-table migration" do
      scaffold
      seed_models
      generate(%w[Item Widget role:string --position=rank --css=daisyui])

      expect(File.read(widget_migration)).to include("t.integer :rank")
      expect(Dir[File.join(@destination, "db/migrate/*.rb")].size).to eq(1)
      expect(generated("app/models/item.rb")).to include("-> { order(:rank) }")
      expect(generated("app/forms/item_form.rb")).to include("attrs[:rank] = i + 1")
      expect(generated("app/forms/widget_form.rb")).to include("reactive_attributes Widget, :role\n")
    end

    it "keeps a parent reference the user typed where they put it" do
      scaffold
      seed_models
      generate(%w[Item Widget role:string item:references --css=daisyui])

      migration = File.read(widget_migration)
      expect(migration.scan("t.references :item").size).to eq(1)
      expect(migration.index("t.string :role")).to be < migration.index("t.references :item")
      expect(generated("app/forms/widget_form.rb")).to include("reactive_attributes Widget, :role\n")
    end

    it "emits a Phlex fields component when the scaffold is Phlex" do
      scaffold(%w[Item --phlex --css=daisyui])
      seed_models
      generate(%w[Item Widget part:references role:string --css=daisyui])

      expect(generated("app/views/items/widget_fields.rb"))
        .to include("class Views::Items::WidgetFields < Views::Base")
      expect_valid_generated_sources(@destination)
      expect_zeitwerk_resolvable_views(@destination)
    end

    describe "refusals that must precede the model write" do
      def expect_nothing_created
        expect(exists?("app/models/widget.rb")).to be(false)
        expect(Dir[File.join(@destination, "db/migrate/*.rb")]).to be_empty
      end

      it "keeps the no-table refusal when the model file exists without a constant" do
        scaffold
        write("app/models/widget.rb", "class Widget < ApplicationRecord\nend\n")
        output = generate(%w[Item Widget role:string --css=daisyui])

        expect(output).to include("Widget has no table yet. Run bin/rails db:migrate first.")
        expect(Dir[File.join(@destination, "db/migrate/*.rb")]).to be_empty
      end

      it "refuses a field list that is only the parent reference" do
        scaffold
        output = generate(%w[Item Widget item:references --css=daisyui])

        expect(output).to include("Widget has no editable columns beyond item_id")
        expect_nothing_created
      end

      it "refuses the bare foreign-key spelling" do
        scaffold
        output = generate(%w[Item Widget item_id:integer role:string --css=daisyui])

        expect(output).to include("Spell the parent column item:references")
        expect_nothing_created
      end

      it "refuses an unscaffolded parent before creating anything" do
        output = generate(%w[Item Widget role:string --css=daisyui])

        expect(output).to include("neither a hibiki:rails scaffold")
        expect_nothing_created
      end
    end
  end

  describe "preflight" do
    it "refuses a parent that is neither scaffolded nor a nested child" do
      expect(generate(%w[Item Credit])).to include("neither a hibiki:rails scaffold")
    end

    it "refuses a child with no model and no field list, teaching the inline syntax" do
      scaffold
      output = generate(%w[Item Widget])

      expect(output).to include("No model Widget")
      expect(output).to include("bin/rails g hibiki:rails:nested Item Widget role:string")
    end

    it "refuses a child that does not belong_to the parent" do
      scaffold
      expect(generate(%w[Item Part])).to include("Part must declare belongs_to :item")
    end
  end
end
