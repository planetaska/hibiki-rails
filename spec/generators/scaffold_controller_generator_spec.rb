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
    #
    # Narrowed for the client-written half of the protocol (data-hibiki-busy,
    # data-hibiki-state): no helper emits those, they are stamped at runtime,
    # and an app's whole relationship with them is a CSS selector. So a
    # selector may read one, and a comment may name one, where markup still
    # may not write one — which is the whole of what the guard was ever about.
    it "never hand-writes a hibiki data attribute, and only reads them in CSS" do
      Dir[File.join(@destination, "app/views/**/*.erb")].each do |view|
        markup = File.read(view)
                     .gsub(/<%#.*?%>/m, "")                            # a comment may NAME one
                     .gsub(%r{/\*.*?\*/}m, "")                         # so may a CSS comment
                     .gsub(/\[data-hibiki-[a-z-]+(?:="[^"]*")?\]/, "") # a selector may READ one
        expect(markup).not_to include("data-hibiki")
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

  # §5.16 end to end: the same command the field-order notice recommends,
  # against a model that exists. Before 3.6 this emitted a form with one live
  # clause, no min:, and a guessed label column — the schema spec proves the
  # merge, and this proves it reaches the files.
  describe "from an explicit field list against a migrated model" do
    before { generate(["Item", "title:string", "shelf:references", "count:integer"]) }

    it "emits the columns in the order the arguments asked for" do
      expect(generated("app/models/item_row.rb")).to include(":id, :title, :shelf_id, :shelf_name, :count")
      expect(generated("app/models/item_query.rb")).to include("SORTABLE = %i[id title count created_at].freeze")
    end

    it "still reads the validators the argument list cannot state" do
      form = generated("app/forms/item_form.rb")

      expect(form).to include(%{title: ("can't be blank" if title.to_s.strip.empty?)})
      expect(form).to include(%{count: ("must be greater than or equal to 0" if count.to_i < 0)})
      expect(generated("app/views/items/_item_form.html.erb")).to include("min: 0")
    end

    it "still resolves the association's label column" do
      expect(generated("app/channels/items_channel.rb")).to include("Shelf.order(:name).pluck(:name, :id)")
    end

    it "omits a column the arguments left out, and every list derived from it" do
      # An explicit list is a subset filter as well as an ordering — that is
      # the point of the lever, so nothing may quietly put `notes` back.
      expect(generated("app/models/item_query.rb")).to include("SEARCHABLE = %i[title].freeze")
      expect(generated("app/models/item_row.rb")).not_to include(":notes")
      expect(generated("app/forms/item_form.rb")).not_to include("notes")
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
    # The rule is "no STYLING class, and no empty class attribute either". The
    # hbk-* hooks are the exception and have to be: they are what the transport
    # stylesheet selects on, they are identical in all three variants, and
    # under this one they are the only classes in the generated views.
    it "--css=none emits no styling class — only the transport state hooks" do
      generate(["Book", *book_fields, "--css=none"])

      Dir[File.join(@destination, "app/views/**/*.erb")].each do |view|
        File.read(view).scan(/class[=:]\s*["']([^"']*)["']/) do |(value)|
          expect(value.split).not_to be_empty
          expect(value.split).to all(start_with("hbk-"))
        end
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

  # The model a belongs_to points AT — the file Rails' own scaffold never
  # touches, and the one that owes this resource the has_many half plus a ping,
  # because a row prints the parent's label rather than its id.
  describe "the parent model injection" do
    before do
      write("app/models/book.rb", "class Book < ApplicationRecord\n  belongs_to :author\nend\n")
      write("app/models/author.rb", "class Author < ApplicationRecord\nend\n")
    end

    it "adds the has_many and the cross-resource ping" do
      output = generate(["Book", *book_fields])
      author = generated("app/models/author.rb")

      expect(author).to include("has_many :books, dependent: :destroy")
      expect(author).to include("ActionCable.server.broadcast(BooksChannel::CHANGED, {})")
      expect(output).to include("app/models/author.rb already existed and was MODIFIED")
    end

    # Reaching each book's own streamable would mean loading the children inside
    # the callback, unbounded, on every write — so the show page keeps the old
    # label until reload. A stated boundary; nobody should "fix" it silently.
    it "pings the collection grain only" do
      generate(["Book", *book_fields])

      expect(generated("app/models/author.rb")).not_to include("BookChannel.changed")
    end

    it "is idempotent per piece" do
      generate(["Book", *book_fields])
      generate(["Book", *book_fields, "--force"])
      author = generated("app/models/author.rb")

      expect(author.scan("has_many :books").size).to eq(1)
      expect(author.scan("BooksChannel::CHANGED").size).to eq(1)
    end

    # A hand-written has_many is a decision, and dependent: is the part of it
    # the user most likely thought about.
    it "leaves an existing has_many alone while still adding the ping" do
      write("app/models/author.rb",
            "class Author < ApplicationRecord\n  has_many :books, dependent: :restrict_with_error\nend\n")
      output = generate(["Book", *book_fields])
      author = generated("app/models/author.rb")

      expect(author).to include("dependent: :restrict_with_error")
      expect(author).not_to include("dependent: :destroy")
      expect(author).to include("BooksChannel::CHANGED")
      expect(output).to include("left alone")
    end

    # `has_many :books_on_loan` CONTAINS "has_many :books". Read as already
    # wired, the parent silently keeps no dependent: option.
    it "does not read a longer association name as the one it wanted" do
      write("app/models/author.rb", "class Author < ApplicationRecord\n  has_many :books_on_loan\nend\n")
      generate(["Book", *book_fields])

      expect(generated("app/models/author.rb")).to include("has_many :books, dependent: :destroy")
    end

    it "prints what is owed when there is no parent file to edit" do
      FileUtils.rm(File.join(@destination, "app/models/author.rb"))
      output = generate(["Book", *book_fields])

      expect(output).to include("app/models/author.rb")
      expect(output).to include("InvalidForeignKey")
      expect(output).to include("has_many :books, dependent: :destroy")
    end

    it "names the child class when the child is namespaced" do
      write("app/models/admin/book.rb", "class Admin::Book < ApplicationRecord\n  belongs_to :author\nend\n")
      generate(["admin/book", *book_fields])

      expect(generated("app/models/author.rb"))
        .to include('has_many :books, class_name: "Admin::Book", dependent: :destroy')
      expect(generated("app/models/author.rb")).to include("Admin::BooksChannel::CHANGED")
      expect_valid_generated_sources(@destination)
    end

    describe "dependent:, derived from the reflection and not the column" do
      before { write("app/models/shelf.rb", "class Shelf < ApplicationRecord\nend\n") }

      # Crate.shelf_id is NULLABLE and the association is still required —
      # belongs_to_required_by_default — so :nullify would leave rows that fail
      # their own validations.
      it "destroys for a required belongs_to over a nullable column" do
        generate(["Crate"])

        expect(generated("app/models/shelf.rb")).to include("has_many :crates, dependent: :destroy")
      end

      it "nullifies for an optional belongs_to over the same column shape" do
        generate(["Basket"])

        expect(generated("app/models/shelf.rb")).to include("has_many :baskets, dependent: :nullify")
      end
    end

    # Category belongs_to :parent, class_name: "Category" — the parent file IS
    # the child file. The ping is already covered; no plural of `parent` is a
    # generator's to invent.
    describe "a self-referential belongs_to" do
      before { write("app/models/category.rb", "class Category < ApplicationRecord\nend\n") }

      it "adds no has_many and does not double the ping" do
        output = generate(["Category"])
        model = generated("app/models/category.rb")

        expect(model).not_to include("has_many")
        expect(model.scan("CategoriesChannel::CHANGED").size).to eq(1)
        expect(output).to include("points back at Category")
        expect(output).to include("has_many :children")
      end
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

    # This used to be skipped on the whole introspection path, on the
    # assumption that a model read from the schema must already declare its
    # inverse. That is a guess, not a check — and it meant the generator spoke
    # when it could not look at the parent and stayed silent when it could.
    it "says what the parent needs on the schema path too, where it can actually check" do
      output = generate(["Item"])

      expect(output).to include("app/models/shelf.rb")
      expect(output).to include("InvalidForeignKey")
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

    # §5.16, the notice half. The order notice offers a lever; before 3.6
    # taking it cost the validators, so the generator recommended something
    # with an unstated price.
    it "does not offer the field-order lever to someone who already used it" do
      expect(generate(["Item"])).to include("fields follow the schema's column order")
      expect(generate(["Item", "title:string", "count:integer", "due_on:date"]))
        .not_to include("fields follow the schema's column order")
    end

    it "names a field the model has no column for instead of emitting it silently" do
      output = generate(["Item", "title:string", "blurb:text"])

      expect(output).to include("Item has no column for blurb")
      expect(output).to include("Check the spelling")
    end

    # One sentence used to cover two different situations and was true of only
    # one of them — and the merge made a third situation reachable.
    it "blames the migration only when the migration is actually the reason" do
      # No Book constant at all: nothing to read, and saying so beats blaming a
      # migration nobody has written yet.
      expect(generate(["Book", *book_fields])).to include("there is no Book yet")

      # Gauge exists and is migrated, and `label`'s validators are all
      # conditional — so its live_errors is thin for the third reason.
      expect(generate(["Gauge", "label:string"]))
        .to include("Gauge declares no validators readable before a round trip")
    end

    it "keeps the field list when it tells you to re-run" do
      # Re-running without the arguments would cost the order the user just
      # chose, which is §5.16 pointing the other way.
      output = generate(["Gauge", "label:string"])

      expect(output).to include("bin/rails g hibiki:rails:scaffold_controller Gauge label:string")
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
