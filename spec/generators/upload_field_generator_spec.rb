# frozen_string_literal: true

require "rails_helper"
require "support/generator_harness"
require_relative "../support/scaffold_models"

RSpec.describe Hibiki::Rails::Generators::UploadFieldGenerator do
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

  def seed_model
    write("app/models/item.rb", <<~RUBY)
      class Item < ApplicationRecord
        belongs_to :shelf
      end
    RUBY
  end

  describe "on an ERB scaffold" do
    before do
      scaffold
      seed_model
      generate(%w[Item photo --css=daisyui])
    end

    it "emits the concern as a prepend-wrapper with dom-keyed pending state" do
      concern = generated("app/channels/concerns/items_channel/photo_upload.rb")

      expect(concern).to include("module ItemsChannel::PhotoUpload")
      expect(concern).to include("included { prepend GraphHooks }")
      expect(concern).to include("@pending_photo = Hibiki::State.new({})")
      expect(concern).to include("def set_photo(data)")
      expect(concern).to include("def remove_photo(data)")
      # Both forms are served: the extras merge fires while editing OR
      # creating, and every action routes on the dom the input sent.
      expect(concern).to include("return locals unless locals[:editing_id] || locals[:creating]")
      expect(concern).to include("extras.merge(photo_upload: @pending_photo.value)")
      expect(concern).to include('dom = data["dom"].to_s')
      expect(concern).to include("@new_form if @creating&.peek")
      # The helpers are attachment-suffixed: a second concern in the same
      # channel must not override them with bodies reading other ivars.
      expect(concern).to include("def update_pending_photo(dom, value)")
      expect(concern).to include("def apply_pending_photo(dom, record)")
      expect(concern).to include("def photo_upload_form(dom)")
      # The record is only touched after a successful commit, via a fresh
      # find — never the frozen row.
      expect(concern).to include("return unless id && @editing_id.peek.nil?")
      expect(concern).to include(%(apply_pending_photo("item_\#{id}", Item.find_by(id: id))))
      expect(concern).to include(%(apply_pending_photo("item_new", record && Item.find_by(id: record.id))))
      # The wrapped hooks call super — replacing them would sever the channel.
      expect(concern.scan(/^\s*(?:locals = )?super$/).size).to eq(5)
      expect(concern.scan("super if defined?(super)").size).to eq(3)
    end

    it "gives the channel exactly one new line — the include" do
      channel = generated("app/channels/items_channel.rb")

      expect(channel).to include("  include Hibiki::Rails::Channel\n  include PhotoUpload\n")
    end

    it "injects the attachment, the virtual attribute and the guarded purge into the model" do
      model = generated("app/models/item.rb")

      expect(model).to include("has_one_attached :photo")
      expect(model).to include("attribute :remove_photo, :boolean, default: false")
      # The guard is what lets a same-submit upload win over the checkbox.
      expect(model)
        .to include('after_save(if: -> { remove_photo && attachment_changes["photo"].nil? }) { photo.purge }')
    end

    it "emits the upload partial with a nameless input riding the extras hash" do
      partial = generated("app/views/items/_photo_upload.html.erb")

      expect(partial).to include("<%# locals: (form:, dom:, extras: {}) -%>")
      expect(partial).to include("extras.fetch(:photo_upload, {})[dom]")
      expect(partial).to include("form.record&.photo_attachment")
      # A File can't ride the channel: tag.input, which emits no name — never
      # file_field_tag, which would.
      expect(partial).to include(%(tag.input type: "file"))
      expect(partial).not_to include("file_field_tag")
      expect(partial).to include(%(upload_field_action_value: "set_photo"))
      expect(partial).to include("upload_field_dom_value: dom")
      expect(partial).to include("attaches on save")
      expect(partial).to include("photo removed on save")
      expect(partial).to include("**on(:remove_photo, with: { dom: dom })")
    end

    it "renders the partial from the row form and the thumbnail from the row" do
      row_form = generated("app/views/items/_item_form.html.erb")
      row = generated("app/views/items/_item.html.erb")

      # EXACTLY once, and immediately before the fieldset's close (the
      # multiselect anchor lesson).
      expect(row_form.scan(%(<%= render "items/photo_upload", form: form, dom: dom, extras: extras %>)).size)
        .to eq(1)
      expect(row_form).to include(%(extras: extras %>\n  </div>))
      # The display reads photo_attachment; the bare proxy memoizes into an
      # ivar and raises FrozenError on the frozen rows.
      expect(row.scan("item.photo_attachment").size).to eq(2)
      expect(row).not_to match(/item\.photo\.\w/)
      expect(row).to include("resize_to_limit: [ 80, 80 ]")
    end

    it "extends both strict_loading preloads" do
      expect(generated("app/models/item_query.rb"))
        .to include("apply_sort(matched_scope.includes(:shelf).with_attached_photo), page: @page")
      expect(generated("app/channels/item_channel.rb"))
        .to include("Item.includes(:shelf).with_attached_photo.strict_loading.find_by(id: record_id)")
    end

    it "injects the classic form field and the guarded remove checkbox" do
      form = generated("app/views/items/_form.html.erb")

      expect(form.scan(%(form.file_field :photo, accept: "image/*", direct_upload: true)).size).to eq(1)
      expect(form).to include("form.checkbox :remove_photo")
      expect(form).to include("Remove photo")
      # Above the submit div, and the checkbox only renders with something
      # attached.
      expect(form.index("file_field :photo")).to be < form.index("form.submit")
      expect(form.scan("<% if item.photo_attachment %>").size).to eq(2)
    end

    it "appends the two scalars to params.expect" do
      controller = generated("app/controllers/items_controller.rb")

      expect(controller.scan(":photo, :remove_photo ])").size).to eq(1)
      expect(controller).not_to include("photo: []")
    end

    it "emits the shared Stimulus controller and compiling sources" do
      js = generated("app/javascript/controllers/upload_field_controller.js")

      expect(js).to include("static values = { url: String, action: String, dom: String }")
      expect(js).to include("performOn(this.element, this.actionValue")
      expect(js).to include('import { DirectUpload } from "@rails/activestorage"')
      expect_valid_generated_sources(@destination)
    end

    it "is idempotent — a re-run changes nothing" do
      before_state = Dir[File.join(@destination, "app/**/*")].to_h { [it, (File.read(it) if File.file?(it))] }
      generate(%w[Item photo --css=daisyui])

      after_state = Dir[File.join(@destination, "app/**/*")].to_h { [it, (File.read(it) if File.file?(it))] }
      expect(after_state).to eq(before_state)
    end
  end

  describe "a second attachment" do
    before do
      scaffold
      seed_model
      generate(%w[Item photo --css=daisyui])
      @output = generate(%w[Item badge_art --css=daisyui])
    end

    it "coexists with the first — chained preloads, both params, one js controller" do
      expect(exists?("app/channels/concerns/items_channel/photo_upload.rb")).to be(true)
      expect(exists?("app/channels/concerns/items_channel/badge_art_upload.rb")).to be(true)
      # Each new include lands right after the anchor, so the later run sits
      # first — harmless, every concern wraps via its own GraphHooks prepend.
      expect(generated("app/channels/items_channel.rb"))
        .to include("  include Hibiki::Rails::Channel\n  include BadgeArtUpload\n  include PhotoUpload\n")
      expect(generated("app/models/item_query.rb"))
        .to include(".with_attached_photo.with_attached_badge_art")
      expect(generated("app/controllers/items_controller.rb"))
        .to include(":photo, :remove_photo, :badge_art, :remove_badge_art ])")
      expect(@output).to include("identical")
      expect(generated("app/views/items/_badge_art_upload.html.erb"))
        .to include("extras.fetch(:badge_art_upload, {})[dom]")
      expect_valid_generated_sources(@destination)
    end
  end

  describe "controller registration" do
    before do
      scaffold
      seed_model
    end

    it "leaves index.js alone in an importmap app — the directory eager-loads" do
      write("config/importmap.rb", "pin \"hibiki-rails\", to: \"hibiki.js\"\n")
      generate(%w[Item photo --css=daisyui])

      expect(exists?("app/javascript/controllers/index.js")).to be(false)
    end

    it "appends the import/register pair once in a jsbundling app" do
      write("app/javascript/controllers/index.js", <<~JS)
        import { application } from "./application"
      JS
      generate(%w[Item photo --css=daisyui])
      generate(%w[Item badge_art --css=daisyui])

      index = generated("app/javascript/controllers/index.js")
      expect(index.scan('application.register("upload-field", UploadFieldController)').size).to eq(1)
    end
  end

  describe "--phlex" do
    before do
      scaffold(%w[Item --phlex --css=daisyui])
      seed_model
      generate(%w[Item photo --css=daisyui])
    end

    it "detects the view layer from the scaffold and emits a component" do
      component = generated("app/views/items/photo_upload.rb")

      expect(component).to include("class Views::Items::PhotoUpload < Views::Base")
      expect(component).to include("def initialize(form:, dom:, extras: {})")
      expect(generated("app/views/items/row_form.rb"))
        .to include("render Views::Items::PhotoUpload.new(form: @form, dom: @dom, extras: @extras)")
      expect(generated("app/views/items/row.rb")).to include("@item.photo_attachment")
    end

    it "injects the page-form method pair and the ImageTag helper includes" do
      form = generated("app/views/items/form.rb")
      row = generated("app/views/items/row.rb")

      expect(form.scan("photo_upload_fields(form)").size).to eq(2)
      expect(form).to include("form.file_field :photo, accept: \"image/*\", direct_upload: true")
      expect(form.scan("include Phlex::Rails::Helpers::ImageTag").size).to eq(1)
      expect(row.scan("include Phlex::Rails::Helpers::ImageTag").size).to eq(1)
    end

    it "emits sources that compile and resolve under Zeitwerk" do
      expect_valid_generated_sources(@destination)
      expect_zeitwerk_resolvable_views(@destination)
    end
  end

  describe "a pre-extras scaffold" do
    before do
      scaffold
      seed_model
      # Strip the 0.7.0 extension point back out, the shape 0.6.0 emitted —
      # the wrapped form too (the list renders each local on its own line).
      %w[_list.html.erb _item.html.erb _item_form.html.erb].each do |basename|
        path = File.join(@destination, "app/views/items", basename)
        File.write(path, File.read(path).gsub(", extras: {}", "").gsub(", extras: extras", "")
                             .gsub(/,\n\s*extras: (\{\}|extras)/, ""))
      end
      @output = generate(%w[Item photo --css=daisyui])
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
          seed_model
          generate(["Item", "photo", *layer, "--css=#{variant}"])

          expect_valid_generated_sources(dir)
        end
      end
    end
  end

  describe "preflight" do
    it "refuses an owner that is not hibiki-scaffolded" do
      expect(generate(%w[Item photo])).to include("is not a hibiki:rails scaffold")
    end

    it "refuses a missing owner model" do
      expect(generate(%w[Widget photo])).to include("No model Widget")
    end

    it "refuses an attachment named after a real column, writing nothing" do
      scaffold
      seed_model

      expect(generate(%w[Item title --css=daisyui])).to include("already has a title column")
      expect(exists?("app/channels/concerns/items_channel/title_upload.rb")).to be(false)
      expect(exists?("app/javascript/controllers/upload_field_controller.js")).to be(false)
    end

    it "refuses an attachment shadowing an association" do
      scaffold
      seed_model

      expect(generate(%w[Item stickers --css=daisyui])).to include("already an association")
    end
  end

  describe "notices" do
    it "warns about every missing prerequisite, tersely" do
      scaffold
      seed_model
      output = generate(%w[Item photo --css=daisyui])

      expect(output).to include("active_storage:install")
      expect(output).to include("image_processing")
      expect(output).to include("ActiveStorage.start()")
    end

    it "asks for the importmap pin only when an importmap has no pin" do
      scaffold
      seed_model
      write("config/importmap.rb", "pin \"hibiki-rails\", to: \"hibiki.js\"\n")
      output = generate(%w[Item photo --css=daisyui])

      expect(output).to include(%(pin "@rails/activestorage"))
    end
  end
end
