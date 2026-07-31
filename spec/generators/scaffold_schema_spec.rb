# frozen_string_literal: true

require "rails_helper"
require_relative "../support/scaffold_models"
require "support/generator_harness"
require "generators/hibiki/rails/scaffold_schema"

# The two sources a scaffold can derive from, and the proof they agree.
#
# `hibiki:rails:scaffold` runs the controller generator BEFORE the migration,
# so it has only a parsed `field:type` list; `hibiki:rails:scaffold_controller
# Book` has only the schema. Every list the templates read has to come out the
# same shape either way, which is what these two describes assert side by side.
RSpec.describe Hibiki::Rails::Generators::ScaffoldSchema do
  def parse(*definitions)
    definitions.map { Rails::Generators::GeneratedAttribute.parse(it) }
  end

  describe ".from_model" do
    subject(:schema) { described_class.from_model(Item) }

    it "walks columns_hash, skipping the primary key and the timestamps" do
      expect(schema.attribute_names).to eq(%i[shelf_id title notes count due_on active])
      expect(schema).to be_introspected
    end

    it "derives the query object's three allowlists from column types" do
      expect(schema.searchable).to eq(%i[title notes])
      expect(schema.filterable).to eq(%i[active])
      # text and boolean are excluded; :id leads and :created_at trails.
      expect(schema.sortable).to eq(%i[id title count due_on created_at])
    end

    it "gives a belongs_to two row members — the key and the label" do
      expect(schema.row_members).to eq(%i[id shelf_id shelf_name title notes count due_on active])
    end

    it "resolves the label column through the association" do
      shelf = schema.belongs_tos.sole
      expect(shelf.label_column).to eq(:name)
      expect(shelf.display_reader).to eq(:shelf_name)
      expect(shelf.association_class_name).to eq("Shelf")
      expect(shelf.options_local).to eq(:shelf_options)
    end

    it "groups the counts on the first boolean" do
      expect(schema.primary_boolean.name).to eq(:active)
    end

    it "builds live errors only from facts the model actually declares" do
      expect(schema.live_errors).to eq(
        [
          [:shelf_id, %{("must be selected" if shelf_id.blank?)}],
          [:title, %{("can't be blank" if title.to_s.strip.empty?)}],
          [:notes, %{("can't be blank" if notes.to_s.strip.empty?)}],
          [:count, %{("must be greater than or equal to 0" if count.to_i < 0)}]
        ]
      )
    end

    it "does not call a null: false column with a default required" do
      # `count` is integer, null: false, default: 0 — a blank submit takes the
      # default, so there is nothing a presence message could warn about. This
      # is why the numericality validator is what earns it an entry above.
      expect(schema.columns.find { it.name == :count }).not_to be_required
      expect(schema.columns.find { it.name == :active }).not_to be_required
    end

    it "reads html bounds off the same numericality validator" do
      expect(schema.columns.find { it.name == :count }.html_bounds).to eq(min: 0)
      expect(schema.columns.find { it.name == :title }.html_bounds).to eq({})
    end

    it "picks a control and an event per type" do
      by_name = schema.columns.index_by(&:name)

      expect(by_name[:shelf_id].tag_field_helper).to eq(:select_tag)
      expect(by_name[:title].tag_field_helper).to eq(:text_field_tag)
      expect(by_name[:notes].tag_field_helper).to eq(:text_area_tag)
      expect(by_name[:count].tag_field_helper).to eq(:number_field_tag)
      expect(by_name[:due_on].tag_field_helper).to eq(:date_field_tag)
      expect(by_name[:active].tag_field_helper).to eq(:check_box_tag)

      # Free text and numbers follow the keystrokes; the rest have no
      # intermediate state worth a round trip.
      expect(by_name[:title].tag_event).to eq(:input)
      expect(by_name[:notes].tag_event).to eq(:input)
      expect(by_name[:count].tag_event).to eq(:input)
      expect(by_name[:due_on].tag_event).to eq(:change)
      expect(by_name[:active].tag_event).to eq(:change)
      expect(by_name[:shelf_id].tag_event).to eq(:change)
    end

    it "humanizes labels through railties, association included" do
      by_name = schema.columns.index_by(&:name)

      expect(by_name[:shelf_id].human_name).to eq("Shelf")
      expect(by_name[:due_on].human_name).to eq("Due on")
    end
  end

  # Regression, measured in a browser during the Phase 2 pass: a nil `print`
  # under `allow_nil: true` showed "must be greater than 0" live while #commit
  # accepted it. A live check that contradicts the model is worse than no live
  # check, because the user sees the contradiction and the generator does not.
  describe ".from_model with validators that cannot be copied naively" do
    subject(:schema) { described_class.from_model(Gauge) }

    it "lets a blank value through a bound the model allows to be blank" do
      expect(schema.live_errors).to eq(
        [
          [:reading, %{("must be greater than 0" if !reading.nil? && reading.to_i <= 0)}],
          [:peak, %{("must be less than 100" if peak.present? && peak.to_i >= 100)}]
        ]
      )
    end

    it "drops conditional validators entirely, message and bound alike" do
      label = schema.columns.find { it.name == :label }

      # `presence: true, if: :calibrated?` and `length:, on: :create` both
      # depend on a fact the form has no access to.
      expect(label).not_to be_required
      expect(label.live_error_clause).to be_nil
      expect(schema.live_errors.map(&:first)).not_to include(:label)
    end

    it "keeps html bounds honest too — no min from a rule it refuses to state" do
      by_name = schema.columns.index_by(&:name)

      expect(by_name[:reading].html_bounds).to eq(min: 1)
      expect(by_name[:peak].html_bounds).to eq(max: 99)
    end
  end

  describe ".from_attributes" do
    subject(:schema) do
      described_class.from_attributes(
        parse("author:references", "title:string", "intro:text", "print:integer",
              "release_date:date", "stock:integer", "available:boolean")
      )
    end

    it "derives the same lists the introspection path does" do
      expect(schema.attribute_names).to eq(%i[author_id title intro print release_date stock available])
      expect(schema.searchable).to eq(%i[title intro])
      expect(schema.filterable).to eq(%i[available])
      expect(schema.sortable).to eq(%i[id title print release_date stock created_at])
      expect(schema.row_members).to eq(%i[id author_id author_name title intro print release_date stock available])
      expect(schema).not_to be_introspected
    end

    it "knows only what the argument list states — a required belongs_to, and nothing else" do
      # No model exists yet, so there are no validators to read. This is the
      # documented asymmetry between the two commands, and the generator says
      # so in its post-install output.
      expect(schema.live_errors).to eq([[:author_id, %{("must be selected" if author_id.blank?)}]])
    end

    it "reads a bang-suffixed scalar as required", if: BANG_SUFFIX do
      # GeneratedAttribute#required? is belongs_to-only; `title:string!` lands
      # in attr_options as null: false and would otherwise be missed.
      schema = described_class.from_attributes(parse("title:string!"))

      expect(schema.columns.sole).to be_required
      expect(schema.live_errors).to eq([[:title, %{("can't be blank" if title.to_s.strip.empty?)}]])
    end

    it "guesses the association label, since no schema can confirm it" do
      expect(schema.belongs_tos.sole.display_reader).to eq(:author_name)
    end

    it "refuses attribute shapes that cannot be a form signal" do
      schema = described_class.from_attributes(
        parse("title:string", "cover:attachment", "body:rich_text", "password:digest")
      )

      expect(schema.attribute_names).to eq(%i[title])
      expect(schema.skipped.map(&:first)).to eq(%w[cover body password])
      expect(schema.skipped.map(&:last)).to all(be_a(String))
    end
  end
end
