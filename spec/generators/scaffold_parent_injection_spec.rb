# frozen_string_literal: true

require "rails_helper"
require "rails/generators"
require "rails/generators/named_base"
require "rails/generators/resource_helpers"
require "support/generator_harness"
require "generators/hibiki/rails/scaffold_helpers"
require "generators/hibiki/rails/scaffold_schema"
require "generators/hibiki/rails/scaffold_parent_injection"

# The derivation half of the parent injection: which file, which association
# name, which options. Exercised through a bare NamedBase like the naming layer
# is, because none of it needs a filesystem — the writing half is covered end to
# end in scaffold_controller_generator_spec.rb.
RSpec.describe Hibiki::Rails::Generators::ScaffoldParentInjection do
  probe = Class.new(Rails::Generators::NamedBase) do
    include Rails::Generators::ResourceHelpers
    include Hibiki::Rails::Generators::ScaffoldHelpers
    include Hibiki::Rails::Generators::ScaffoldParentInjection

    def self.name = "ScaffoldParentInjectionProbe"

    def call(method, ...) = send(method, ...)
  end

  define_method(:injection_for) { |name| probe.new([name]) }

  # ScaffoldColumn asks a reflection for exactly three things, so a Struct is
  # enough — and a double keeps the renamed-foreign-key case out of the schema
  # fixtures, where it would need a table nothing else uses.
  reflection = Struct.new(:name, :foreign_key, :class_name)

  def column_for(reflection, required: true)
    attr = Rails::Generators::GeneratedAttribute.parse("#{reflection.name}:references")
    Hibiki::Rails::Generators::ScaffoldColumn.new(attr: attr, reflection: reflection, required: required)
  end

  describe "which file it edits" do
    it "derives the path from the reflection's class name" do
      column = column_for(reflection.new(:author, "author_id", "Author"))

      expect(injection_for("Book").call(:parent_model_path, column)).to eq("app/models/author.rb")
    end

    it "nests a namespaced parent the way model_path does" do
      column = column_for(reflection.new(:author, "author_id", "Admin::Author"))

      expect(injection_for("Book").call(:parent_model_path, column)).to eq("app/models/admin/author.rb")
    end
  end

  describe "the has_many line" do
    it "needs no options beyond dependent: in the plain case" do
      column = column_for(reflection.new(:author, "author_id", "Author"))

      expect(injection_for("Book").call(:inverse_line, column))
        .to eq("has_many :books, dependent: :destroy")
    end

    # The reflection decides, not the column: Basket's shelf_id is nullable too.
    it "nullifies when the belongs_to is optional" do
      column = column_for(reflection.new(:author, "author_id", "Author"), required: false)

      expect(injection_for("Book").call(:inverse_line, column))
        .to eq("has_many :books, dependent: :nullify")
    end

    # `has_many :books` on a top-level Author resolves ::Book, never Admin::Book
    # — compute_type walks the DECLARING class's nesting.
    it "names the class when the child is namespaced" do
      column = column_for(reflection.new(:author, "author_id", "Author"))

      expect(injection_for("admin/book").call(:inverse_line, column))
        .to eq('has_many :books, class_name: "Admin::Book", dependent: :destroy')
    end

    # Passing :foreign_key switches OFF automatic inverse detection, so the two
    # options are emitted as a pair or every hop reloads the record it came from.
    it "names the foreign key AND the inverse when the belongs_to was renamed" do
      column = column_for(reflection.new(:writer, "writer_id", "Author"))

      expect(injection_for("Book").call(:inverse_line, column))
        .to eq("has_many :books, foreign_key: :writer_id, inverse_of: :writer, dependent: :destroy")
    end

    it "reproduces Rails' own foreign-key guess for a namespaced parent" do
      column = column_for(reflection.new(:author, "author_id", "Admin::Author"))

      # Inflector#foreign_key demodulizes, and so does derive_foreign_key — so
      # author_id is NOT a mismatch here and no options are owed.
      expect(injection_for("Book").call(:inverse_line, column))
        .to eq("has_many :books, dependent: :destroy")
    end
  end

  describe "the has_many marker" do
    it "matches the declaration it would have written" do
      expect(injection_for("Book").call(:inverse_marker)).to match("  has_many :books, dependent: :destroy")
    end

    # A plain substring test reads this as "already wired" and leaves the parent
    # with no dependent: option while the generator reports success.
    it "does not match a different association that merely starts the same way" do
      expect(injection_for("Book").call(:inverse_marker)).not_to match("  has_many :books_on_loan")
    end
  end
end
