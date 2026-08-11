# frozen_string_literal: true

require "rails_helper"
require "support/generator_harness"
require_relative "../support/scaffold_models"

RSpec.describe Hibiki::Rails::Generators::FormGenerator do
  include GeneratorHarness

  around do |example|
    Dir.mktmpdir do |dir|
      @destination = dir
      example.run
    end
  end

  def generated(path) = File.read(File.join(@destination, path))
  def exists?(path) = File.exist?(File.join(@destination, path))

  def generate(args)
    run_generator(described_class, args, destination: @destination)
  end

  def write(path, content)
    full = File.join(@destination, path)
    FileUtils.mkdir_p(File.dirname(full))
    File.write(full, content)
  end

  describe "from the schema, with no field list" do
    before { generate(["Item"]) }

    it "derives live errors from the model's validators" do
      form = generated("app/forms/item_form.rb")

      expect(form).to include("reactive_attributes Item, :shelf_id, :title, :notes, :count, :due_on,")
      expect(form).to include(%{shelf_id: ("must be selected" if shelf_id.blank?)})
      expect(form).to include(%{title: ("can't be blank" if title.to_s.strip.empty?)})
      expect(form).to include(%{count: ("must be greater than or equal to 0" if count.to_i < 0)})
    end

    it "rewrites both form views, with bounds off the same validators" do
      expect(generated("app/views/items/_form.html.erb")).to include("min: 0")
      expect(generated("app/views/items/_item_form.html.erb")).to include("min: 0")
    end

    it "emits the shared error partials but never the page control" do
      expect(exists?("app/views/shared/_field_error.html.erb")).to be(true)
      expect(exists?("app/views/shared/_form_errors.html.erb")).to be(true)
      expect(exists?("app/views/shared/_pagination.html.erb")).to be(false)
    end

    it "leaves the rest of the scaffold's output alone" do
      expect(exists?("app/channels/items_channel.rb")).to be(false)
      expect(exists?("app/controllers/items_controller.rb")).to be(false)
      expect(exists?("app/models/item_query.rb")).to be(false)
      expect(exists?("app/views/items/index.html.erb")).to be(false)
    end

    it "emits sources that compile" do
      expect_valid_generated_sources(@destination)
    end
  end

  describe "with an explicit field list" do
    it "takes the order and subset from the arguments, the facts from the schema" do
      generate(["Item", "title:string", "shelf:references"])
      form = generated("app/forms/item_form.rb")

      expect(form).to include("reactive_attributes Item, :title, :shelf_id")
      expect(form).to include(%{title: ("can't be blank" if title.to_s.strip.empty?)})
      expect(form).not_to include("notes")
    end
  end

  describe "--skip-views" do
    it "rewrites only the form object" do
      generate(["Item", "--skip-views"])

      expect(exists?("app/forms/item_form.rb")).to be(true)
      expect(exists?("app/views/items/_form.html.erb")).to be(false)
      expect(exists?("app/views/shared/_field_error.html.erb")).to be(false)
    end
  end

  describe "the view layer" do
    it "detects a previous --phlex run from the component it left behind" do
      write("app/views/items/form.rb", "class Views::Items::Form < Views::Base\nend\n")
      generate(["Item"])

      expect(generated("app/views/items/form.rb")).to include("class Views::Items::Form < Views::Base")
      expect(generated("app/views/items/row_form.rb")).to include("class Views::Items::RowForm < Views::Base")
      expect(exists?("app/views/items/_form.html.erb")).to be(false)
      expect(exists?("app/views/shared/field_error.rb")).to be(true)
      expect_zeitwerk_resolvable_views(@destination)
      expect_valid_generated_sources(@destination)
    end

    it "--phlex overrides detection when there is nothing to detect from" do
      generate(["Item", "--phlex"])

      expect(exists?("app/views/items/form.rb")).to be(true)
      expect(exists?("app/views/items/_form.html.erb")).to be(false)
    end
  end

  describe "when the schema cannot be read" do
    it "aborts on a missing model rather than emitting an underived form" do
      output = generate(["Nonexistent"])

      expect(output).to include("No model Nonexistent")
      expect(exists?("app/forms/nonexistent_form.rb")).to be(false)
    end

    it "aborts on a model whose table has not been migrated" do
      stub_const("Phantom", Class.new(ActiveRecord::Base))
      output = generate(["Phantom"])

      expect(output).to include("Phantom has no table yet. Run bin/rails db:migrate first")
      expect(exists?("app/forms/phantom_form.rb")).to be(false)
    end
  end

  describe "post-install output" do
    it "says when the model still declares no readable validators, command on its own line" do
      output = generate(["Basket"])

      # Thor indents a status message's continuation lines under the status
      # column, so the advice and the copyable command each get their own line.
      expect(output).to include("Basket declares no validators readable")
      rerun = %r{^ +Add validators to the model, migrate, then re-run\n +bin/rails g hibiki:rails:form Basket$}
      expect(output).to match(rerun)
    end

    it "stays quiet about validators once the model declares some" do
      output = generate(["Item"])

      expect(output).not_to include("live_errors is empty")
    end

    it "still names an unmirrored unique index — #commit is where that bites" do
      output = generate(["Badge"])

      expect(output).to include("validates :slug, uniqueness: true")
    end
  end
end
