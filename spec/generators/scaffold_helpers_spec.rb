# frozen_string_literal: true

require "rails_helper"
require "rails/generators"
require "rails/generators/named_base"
require "rails/generators/resource_helpers"
require "support/generator_harness"
require "generators/hibiki/rails/scaffold_helpers"

# The naming layer, exercised through a bare NamedBase rather than a real
# generator: these are the values every template interpolates, and getting one
# grain wrong produces output that subscribes successfully and never receives a
# broadcast.
RSpec.describe Hibiki::Rails::Generators::ScaffoldHelpers do
  probe = Class.new(Rails::Generators::NamedBase) do
    include Rails::Generators::ResourceHelpers
    include Hibiki::Rails::Generators::ScaffoldHelpers

    def self.name = "ScaffoldHelpersProbe"

    # The module is private by design (a public method on a Thor generator is a
    # command), so the probe opens one door rather than making them all public.
    def call(method, ...) = send(method, ...)
  end

  # define_method, not def: `probe` is a block-local and a def body would not
  # close over it.
  define_method(:helpers_for) { |name| probe.new([name]) }

  describe "the two grains" do
    it "names a collection at the plural grain and a record at the singular one" do
      book = helpers_for("Book")

      expect(book.call(:collection_channel_class_name)).to eq("BooksChannel")
      expect(book.call(:member_channel_class_name)).to eq("BookChannel")
      expect(book.call(:collection_stream_name)).to eq("books")
      expect(book.call(:member_stream_name)).to eq("book")
      expect(book.call(:changed_streamable)).to eq("books:changed")
    end

    it "keeps both grains distinct under a namespace" do
      admin = helpers_for("admin/book")

      expect(admin.call(:collection_channel_class_name)).to eq("Admin::BooksChannel")
      expect(admin.call(:member_channel_class_name)).to eq("Admin::BookChannel")
      # ActionCable derives channel_name by stripping "Channel" and turning
      # "::" into ":", so these agree with the class names by construction.
      expect(admin.call(:collection_stream_name)).to eq("admin:books")
      expect(admin.call(:member_stream_name)).to eq("admin:book")
      expect(admin.call(:changed_streamable)).to eq("admin:books:changed")
    end
  end

  describe "destinations" do
    it "places every emitted file under the namespace" do
      admin = helpers_for("admin/book")

      expect(admin.call(:collection_channel_path)).to eq("app/channels/admin/books_channel.rb")
      expect(admin.call(:member_channel_path)).to eq("app/channels/admin/book_channel.rb")
      # app/models, not a new app/queries: Rails computes autoload paths from
      # the app/* glob at boot, so a new top-level dir needs a restart.
      expect(admin.call(:query_path)).to eq("app/models/admin/book_query.rb")
      expect(admin.call(:form_path)).to eq("app/forms/admin/book_form.rb")
      expect(admin.call(:scaffold_controller_path)).to eq("app/controllers/admin/books_controller.rb")
      expect(admin.call(:view_dir)).to eq("app/views/admin/books")
    end

    it "namespaces dom ids and reactive value names so two islands can share a page" do
      admin = helpers_for("admin/book")

      expect(admin.call(:list_dom_id)).to eq("admin_books")
      expect(admin.call(:row_dom_id_prefix)).to eq("admin_book")
      expect(admin.call(:value_name, "total")).to eq("admin_books_total")
      # Helpers.value_name would raise on anything outside this shape.
      expect(admin.call(:value_name, "total")).to match(/\A[a-z][a-z0-9_-]*\z/i)
    end

    it "keeps the row partial singular, matching Rails' own scaffold" do
      expect(helpers_for("admin/book").call(:row_partial)).to eq("book")
    end
  end

  describe "#to_argv" do
    # The reason this method exists: GeneratedAttribute#to_s is not a
    # round-trip. `title:string!` comes back as "title:string{null}" — where
    # print_attribute_options falls through to joining option KEYS — and .parse
    # then rejects it with "unknown type 'string{null}'". The scaffold
    # generator hands attributes to the controller generator as argv, so this
    # would corrupt every required field.
    %w[
      author:references
      intro:text{small}
      price:decimal{10,2}
      code:string{30}:uniq
      slug:string:index
      owner:references{polymorphic}
    ].each do |definition|
      it "round-trips #{definition}" do
        attribute = Rails::Generators::GeneratedAttribute.parse(definition)

        expect(helpers_for("Book").call(:to_argv, attribute)).to eq(definition)
      end
    end

    it "round-trips title:string!" do
      attribute = Rails::Generators::GeneratedAttribute.parse("title:string!")

      expect(helpers_for("Book").call(:to_argv, attribute)).to eq("title:string!")
    end

    it "is not what railties' own to_s would have produced" do
      attribute = Rails::Generators::GeneratedAttribute.parse("title:string!")

      expect(attribute.to_s).to eq("title:string{null}")
      expect { Rails::Generators::GeneratedAttribute.parse(attribute.to_s) }
        .to raise_error(Rails::Generators::Error, /unknown type/)
    end
  end
end
