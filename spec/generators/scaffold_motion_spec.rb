# frozen_string_literal: true

require "rails_helper"
require "support/generator_harness"
require_relative "../support/scaffold_models"

# Motion: what a generated app needs so a marked element can slide in and
# out — the stylesheet naming the classes, the import of the client module
# that holds a render, and the marks in the views. On by default; both
# --skip-motion and --css=none leave every trace out.
RSpec.describe Hibiki::Rails::Generators::ScaffoldControllerGenerator, "motion" do
  include GeneratorHarness

  def stylesheet = "app/assets/stylesheets/hibiki_motion.css"
  def entry = "app/assets/stylesheets/application.tailwind.css"
  def layout_path = "app/views/layouts/application.html.erb"
  def application_js = "app/javascript/application.js"
  def classes = %w[hbk-slide hbk-slide-body hbk-slide-x hbk-slide-x-body hbk-fade hbk-fly hbk-scale hbk-blur]

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

  def write(path, body)
    full = File.join(@destination, path)
    FileUtils.mkdir_p(File.dirname(full))
    File.write(full, body)
  end

  def layout = write(layout_path, %(<html><head>\n  <%= stylesheet_link_tag "application" %>\n</head></html>\n))

  def generate(args = [], name: "Book", destination: @destination)
    run_generator(described_class, [name, *book_fields, *args], destination: destination)
  end

  def reset_app = FileUtils.rm_rf(Dir[File.join(@destination, "app")])

  describe "the stylesheet" do
    # @utility, never a plain class: a plain .hbk-slide in the components
    # layer loses display and transition to daisyUI's .card, imported after
    # it; a utility sits above every component, and a single utility on the
    # element still wins because Tailwind orders multi-property ones first.
    it "ships with both styled variants, every class a utility" do
      %w[daisyui tailwind].each do |variant|
        reset_app
        generate(["--css=#{variant}"])

        css = generated(stylesheet)
        expect(css).not_to include("@layer")
        classes.each { expect(css).to include("@utility #{it} {") }
      end
    end

    it "is one file for the whole app, beside the busy sheet" do
      generate(%w[--css=daisyui])
      generate(%w[--css=daisyui], name: "Item")

      names = Dir[File.join(@destination, "app/assets/stylesheets/*.css")].map { File.basename(it) }
      expect(names).to contain_exactly("hibiki_busy.css", "hibiki_motion.css")
    end

    it "imports from the entry stylesheet, below the busy sheet, and says where to tune it" do
      write(entry, %(@import "tailwindcss";\n))

      output = generate(%w[--css=daisyui])

      expect(generated(entry))
        .to eq(%(@import "tailwindcss";\n@import "./hibiki_busy.css";\n@import "./hibiki_motion.css";\n))
      expect(output).to include("#{stylesheet} was created and imported from your entry stylesheet")
      expect(output).to include("duration and easing are tuned there")
    end

    it "imports at most once across two resources" do
      write(entry, %(@import "tailwindcss";\n))
      generate(%w[--css=daisyui])
      generate(%w[--css=daisyui], name: "Item")

      expect(generated(entry).scan("hibiki_motion").size).to eq(1)
    end

    # Both sheets land after the stock tag, each once: the anchor never
    # matches one of our own tags, or the second sheet would land twice.
    it "links from the layout once per sheet when nothing else carries it" do
      layout
      generate(%w[--css=daisyui])
      generate(%w[--css=daisyui], name: "Item")

      body = generated(layout_path)
      expect(body.scan(%(stylesheet_link_tag "hibiki_motion")).size).to eq(1)
      expect(body.scan(%(stylesheet_link_tag "hibiki_busy")).size).to eq(1)
      expect(body.scan("stylesheet_link_tag").size).to eq(3)
    end

    it "prints the line to paste when it cannot wire anything" do
      output = generate(%w[--css=daisyui])

      expect(output).to include("#{stylesheet} was created but nothing links it, so nothing will slide")
      expect(output).to include(%(stylesheet_link_tag "hibiki_motion"))
    end
  end

  describe "the client module" do
    it "is imported from the JavaScript entry point, once" do
      write(application_js, %(import "@hotwired/turbo-rails"\n))

      output = generate(%w[--css=daisyui])
      generate(%w[--css=daisyui], name: "Item")

      expect(generated(application_js)).to eq(%(import "@hotwired/turbo-rails"\nimport "hibiki-rails/motion"\n))
      expect(output).to include("#{application_js} now imports hibiki-rails/motion")
    end

    it "says what to import when the entry point is missing" do
      output = generate(%w[--css=daisyui])

      expect(output).to include("#{application_js} not found, so nothing will slide")
      expect(output).to include(%(import "hibiki-rails/motion"))
    end
  end

  describe "the marks" do
    it "marks the row, its edit and display wrappers, and the create card" do
      generate(%w[--css=daisyui])

      row = generated("app/views/books/_book.html.erb")
      expect(row).to include(%(<div id="book_<%= book.id %>" data-motion="own" class="hbk-slide-x">))
      expect(row).to include(%(<div class="hbk-slide-x-body card bg-base-100 shadow-sm card-body">))
      expect(row).to include(%(<div id="book_<%= book.id %>_edit" data-motion class="hbk-slide">))
      expect(row).to include(%(<div class="hbk-slide-body">))
      expect(row).to include(%(<div id="book_<%= book.id %>_display" class="contents">))

      list = generated("app/views/books/_list.html.erb")
      expect(list).to include(%(<div id="book_new" data-motion class="hbk-slide card bg-base-100 shadow-sm">))
      expect(list).to include(%(<div class="hbk-slide-body card-body">))
    end

    it "marks the same elements in Phlex, the empty mark as a bare attribute" do
      generate(%w[--css=daisyui --phlex])

      row = generated("app/views/books/row.rb")
      expect(row).to include(%(div(id: "book_\#{@book.id}", data: { motion: "own" }, class: "hbk-slide-x") do))
      expect(row).to include(%(div(class: "hbk-slide-x-body card bg-base-100 shadow-sm card-body") do))
      expect(row)
        .to include(%(div(id: "book_\#{@book.id}_edit", data: { motion: true }, class: "hbk-slide") do))
      expect(row).to include(%(div(class: "hbk-slide-body") do))
      expect(row).to include(%(div(id: "book_\#{@book.id}_display", class: "contents") { fields }))

      list = generated("app/views/books/list.rb")
      expect(list)
        .to include(%(div(id: "book_new", data: { motion: true }, class: "hbk-slide card bg-base-100 shadow-sm") do))
      expect(list).to include(%(div(class: "hbk-slide-body card-body") do))
    end

    it "dresses the row with the plain Tailwind tokens under --css=tailwind" do
      generate(%w[--css=tailwind])

      row = generated("app/views/books/_book.html.erb")
      expect(row)
        .to include(%(class="hbk-slide-x-body rounded-lg border border-gray-200 bg-white shadow-sm p-6 space-y-2">))
    end

    # The row's card and body are ONE element under motion, so the display
    # markup keeps the column the add-on generators anchor their injections
    # on — and the display wrapper closes after the actions block, so an
    # injected display line lands inside it.
    it "keeps the display markup at the column the add-ons anchor on, inside the display wrapper" do
      generate(%w[--css=daisyui])

      row = generated("app/views/books/_book.html.erb")
      expect(row.scan(/^ {4}<% if actions %>$/).size).to eq(1)
      expect(row.index("_display")).to be < row.index("<% if actions %>")
      expect(row).to include("    <% end %>\n    </div>\n    <% end %>\n  </div>\n</div>\n")
    end
  end

  describe "--skip-motion" do
    it "leaves every trace out" do
      write(application_js, %(import "@hotwired/turbo-rails"\n))

      output = generate(%w[--css=daisyui --skip-motion])

      expect(exists?(stylesheet)).to be(false)
      expect(generated(application_js)).to eq(%(import "@hotwired/turbo-rails"\n))
      views = Dir[File.join(@destination, "app/views/**/*")].select { File.file?(it) }.map { File.read(it) }.join
      expect(views).not_to include("data-motion")
      expect(views).not_to include("hbk-slide")
      expect(output).not_to include("motion")
    end

    it "keeps the row's single card" do
      generate(%w[--css=daisyui --skip-motion])

      expect(generated("app/views/books/_book.html.erb"))
        .to include(%(<div id="book_<%= book.id %>" class="card bg-base-100 shadow-sm">\n  <div class="card-body">\n))
    end
  end

  # A hand-styled app: no stylesheet to ride, so motion is not offered at
  # all — the byte-identical claim, provable here.
  describe "--css=none" do
    def snapshot(dir)
      Dir[File.join(dir, "app/**/*")].select { File.file?(it) }
                                     .to_h { [it.delete_prefix(dir), File.read(it)] }
    end

    it "emits exactly what --css=none --skip-motion emits" do
      with_motion = Dir.mktmpdir do |dir|
        generate(%w[--css=none], destination: dir)
        snapshot(dir)
      end
      without = Dir.mktmpdir do |dir|
        generate(%w[--css=none --skip-motion], destination: dir)
        snapshot(dir)
      end

      expect(with_motion).to eq(without)
      expect(with_motion.keys.join).not_to include("hibiki_motion")
      expect(with_motion.values.join).not_to include("data-motion")
    end
  end
end
