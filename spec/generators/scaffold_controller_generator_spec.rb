# frozen_string_literal: true

require "rails_helper"
require "support/generator_harness"
require_relative "../support/scaffold_models"

RSpec.describe Hibiki::Rails::Generators::ScaffoldControllerGenerator do
  include GeneratorHarness

  around do |example|
    Dir.mktmpdir do |dir|
      @destination = dir
      # Seeded so the route action has a file to edit; without one every
      # example prints a "does not appear to exist" warning that buries the
      # assertions being made.
      FileUtils.mkdir_p(File.join(dir, "config"))
      File.write(File.join(dir, "config/routes.rb"), "Rails.application.routes.draw do\nend\n")
      example.run
    end
  end

  # A method rather than a constant: a constant inside a describe block leaks
  # into the global namespace and rubocop rightly objects.
  def book_fields
    %w[author:references title:string intro:text print:integer
       release_date:date stock:integer available:boolean]
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

  describe "from an explicit field list" do
    before { generate(["Book", *book_fields, "--css=daisyui"]) }

    it "derives the query object's allowlists from column types" do
      query = generated("app/models/book_query.rb")

      expect(query).to include("SEARCHABLE = %i[title intro].freeze")
      expect(query).to include("FILTERABLE = %i[available].freeze")
      expect(query).to include("SORTABLE = %i[id title print release_date stock created_at].freeze")
      expect(query).to include("includes(:author)")
    end

    it "gives the row projection a label member per belongs_to" do
      expect(generated("app/models/book_row.rb"))
        .to include(":id, :author_id, :author_name, :title")
    end

    it "declares every attribute on the form" do
      expect(generated("app/forms/book_form.rb"))
        .to include("reactive_attributes Book, :author_id, :title, :intro, :print, :release_date,")
    end

    it "emits one channel action per boolean column" do
      expect(generated("app/channels/books_channel.rb")).to include("def set_available(data)")
    end

    it "emits both grains of channel" do
      expect(generated("app/channels/books_channel.rb"))
        .to include('CHANGED = "books:changed"')
      expect(generated("app/channels/book_channel.rb"))
        .to include(%(def self.changed(id) = "book:\#{id}:changed"))
    end

    it "ships no repaint mitigation — the effect equality gate makes it unnecessary" do
      channel = generated("app/channels/books_channel.rb")

      expect(channel).not_to include("broadcast_refresh_effect")
      expect(channel).not_to include("Debounce")
    end

    it "carries neither pagination mode's discriminator — the mode is resolved here" do
      query = generated("app/models/book_query.rb")

      expect(query).not_to include("MODE")
      expect(query).not_to include("INFINITE")
    end

    # The gem's private Ruby<->JS contract: app code always goes through
    # Hibiki::Rails::Helpers. Inherited verbatim from the island generator's
    # own guard, because generated views are app code too.
    it "never hand-writes a hibiki data attribute" do
      Dir[File.join(@destination, "app/views/**/*.erb")].each do |view|
        expect(File.read(view)).not_to include("data-hibiki")
      end
    end
  end

  describe "from the schema, with no field list" do
    before { generate(["Item"]) }

    it "reads columns, types and reflections off the model" do
      query = generated("app/models/item_query.rb")

      expect(query).to include("SEARCHABLE = %i[title notes].freeze")
      expect(query).to include("FILTERABLE = %i[active].freeze")
      expect(query).to include("SORTABLE = %i[id title count due_on created_at].freeze")
      expect(query).to include("includes(:shelf)")
    end

    it "resolves the association's label column through the association" do
      expect(generated("app/models/item_row.rb")).to include(":shelf_id, :shelf_name")
      expect(generated("app/channels/items_channel.rb")).to include("Shelf.order(:name).pluck(:name, :id)")
    end

    # The introspection path is the only one that can read validators, which is
    # why per-field feedback is richer here than from an argument list.
    it "builds live errors from the model's declared validators" do
      form = generated("app/forms/item_form.rb")

      expect(form).to include(%{shelf_id: ("must be selected" if shelf_id.blank?)})
      expect(form).to include(%{title: ("can't be blank" if title.to_s.strip.empty?)})
      expect(form).to include(%{count: ("must be greater than or equal to 0" if count.to_i < 0)})
    end

    it "takes html bounds off the same numericality validator" do
      expect(generated("app/views/items/_item_form.html.erb")).to include("min: 0")
    end
  end

  describe "when the schema cannot be read" do
    it "aborts with the two ways forward rather than emitting an empty scaffold" do
      output = generate(["Nonexistent"])

      expect(output).to include("No model Nonexistent")
      expect(output).to include("hibiki:rails:scaffold_controller Nonexistent title:string")
      expect(exists?("app/channels/nonexistents_channel.rb")).to be(false)
    end
  end

  describe "options" do
    it "--css=none emits no class attribute at all, not an empty one" do
      generate(["Book", *book_fields, "--css=none"])

      Dir[File.join(@destination, "app/views/**/*.erb")].each do |view|
        expect(File.read(view)).not_to match(/class[=:]\s*["']/)
      end
    end

    it "--css=daisyui and --css=tailwind fork only the page control" do
      generate(["Book", *book_fields, "--css=tailwind"])

      # DaisyUI's `join-item btn` is a component class plain Tailwind lacks, so
      # the item styling has to become a template local.
      expect(generated("app/views/books/_pagination.html.erb")).to include("<% item = ")
      expect(generated("app/views/books/_book.html.erb")).to include("rounded-lg border border-gray-200")
    end

    it "--skip-pagination degrades through a constant, not template conditionals" do
      generate(["Book", *book_fields, "--skip-pagination"])

      expect(generated("app/models/book_query.rb")).to include("PAGE_SIZE = nil")
      # .limit(nil) and .offset(nil) are relation no-ops, so the page control
      # simply never renders and go_to_page short-circuits.
      expect(exists?("app/views/books/_pagination.html.erb")).to be(true)
    end

    it "--infinite-scroll swaps the window function and drops the page control" do
      generate(["Book", *book_fields, "--infinite-scroll"])

      expect(generated("app/models/book_query.rb")).to include("relation.limit(PAGE_SIZE && page * PAGE_SIZE)")
      expect(generated("app/views/books/_list.html.erb")).to include("%i[click visible]")
      expect(exists?("app/views/books/_pagination.html.erb")).to be(false)
    end

    it "--skip-search removes the box, the action and the LIKE terms together" do
      generate(["Book", *book_fields, "--skip-search"])

      expect(generated("app/models/book_query.rb")).not_to include("SEARCHABLE")
      expect(generated("app/channels/books_channel.rb")).not_to include("def search(data)")
      expect(generated("app/views/books/_controls.html.erb")).not_to include("search_field_tag")
    end

    it "--page-size reaches the query object" do
      generate(["Book", *book_fields, "--page-size=5"])

      expect(generated("app/models/book_query.rb")).to include("PAGE_SIZE = 5")
    end
  end

  describe "the model injection" do
    before do
      write("app/models/book.rb", "class Book < ApplicationRecord\n  belongs_to :author\nend\n")
    end

    it "adds the delegate and the ping, and says that it modified the file" do
      output = generate(["Book", *book_fields])
      model = generated("app/models/book.rb")

      expect(model).to include("delegate :name, to: :author, prefix: true, allow_nil: true")
      expect(model).to include("ActionCable.server.broadcast(BooksChannel::CHANGED, {})")
      expect(model).to include("ActionCable.server.broadcast(BookChannel.changed(id), {})")
      expect(output).to include("was MODIFIED")
    end

    it "is idempotent" do
      generate(["Book", *book_fields])
      generate(["Book", *book_fields, "--force"])

      expect(generated("app/models/book.rb").scan("BooksChannel::CHANGED").size).to eq(1)
    end

    it "prints the snippet when there is no model file to edit" do
      FileUtils.rm(File.join(@destination, "app/models/book.rb"))
      output = generate(["Book", *book_fields])

      expect(output).to include("app/models/book.rb not found")
      expect(output).to include("after_commit do")
    end

    # Thor anchors inject_into_class on /class #{klass}\n|class #{klass} .*\n/,
    # so the anchor has to be spelled the way the FILE spells it. Rails' own
    # model template emits the COMPACT form outside an isolated engine, and a
    # demodulized "Book" matches neither "class Admin::Book <" nor the nested
    # "module Admin / class Book". A miss is not an error either: Thor writes
    # the file back byte-identical and the generator announces a modification
    # that never happened.
    it "injects into a namespaced model written in the compact form" do
      write("app/models/admin/book.rb", "class Admin::Book < ApplicationRecord\n  belongs_to :author\nend\n")
      generate(["admin/book", *book_fields])

      expect(generated("app/models/admin/book.rb")).to include("delegate :name, to: :author")
      expect(generated("app/models/admin/book.rb")).to include("Admin::BooksChannel::CHANGED")
    end

    it "injects into a namespaced model written in the nested form" do
      write("app/models/admin/book.rb",
            "module Admin\n  class Book < ApplicationRecord\n    belongs_to :author\n  end\nend\n")
      generate(["admin/book", *book_fields])

      expect(generated("app/models/admin/book.rb")).to include("delegate :name, to: :author")
      expect(generated("app/models/admin/book.rb")).to include("Admin::BooksChannel::CHANGED")
    end
  end

  describe "routes" do
    it "adds the resource route" do
      write("config/routes.rb", "Rails.application.routes.draw do\nend\n")
      generate(["Book", *book_fields])

      expect(generated("config/routes.rb")).to include("resources :books")
    end

    it "does not stack a duplicate when the route is already declared" do
      write("config/routes.rb", "Rails.application.routes.draw do\n  resources :books\nend\n")
      generate(["Book", *book_fields])

      expect(generated("config/routes.rb").scan("resources :books").size).to eq(1)
    end
  end

  describe "post-install output" do
    # Every notice here warns about something that fails SILENTLY. They also
    # run LAST, so this doubles as a guard that nothing earlier aborts the
    # sequence — a missing config/routes.rb once did exactly that.
    it "names what will not work until you act on it" do
      output = generate(["Item"])

      expect(output).to include("restart")
      expect(output).to include("autoload paths")
      expect(output).to include("using Shelf#name as the display label")
      expect(output).to include("bin/rails g hibiki:rails:install")
    end

    it "suggests a field list using association names, not foreign keys" do
      output = generate(["Item"])

      expect(output).to include("shelf:references")
      expect(output).not_to include("shelf_id:references")
    end

    it "reports refused columns rather than dropping them quietly" do
      output = generate(["Book", *book_fields, "cover:attachment"])

      expect(output).to include("cover")
      expect(output).to include("Active Storage")
    end
  end

  it "generates valid sources for a namespaced name" do
    generate(["admin/book", *book_fields])

    # Both grains have to stay distinct: a collection channel streaming from
    # the singular name would subscribe fine and never receive a broadcast.
    expect(generated("app/channels/admin/books_channel.rb")).to include("class Admin::BooksChannel")
    expect(generated("app/channels/admin/books_channel.rb")).to include('CHANGED = "admin:books:changed"')
    expect(generated("app/channels/admin/book_channel.rb")).to include("class Admin::BookChannel")
    expect(generated("app/views/admin/books/_list.html.erb")).to include('<div id="admin_books"')

    expect_valid_generated_sources(@destination)
  end

  it "generates valid sources for every css variant" do
    Hibiki::Rails::Generators::CssVariant::NAMES.each do |variant|
      Dir.mktmpdir do |dir|
        run_generator(described_class, ["Book", *book_fields, "--css=#{variant}"], destination: dir)
        expect_valid_generated_sources(dir)
      end
    end
  end
end
