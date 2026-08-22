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
      expect(partial).to include(%(tag.input type: "file", accept: "image/*"))
      expect(partial).not_to include("file_field_tag")
      # The display branches per blob: an image thumbnails, anything else
      # shows its filename — so a wrong-typed file never 500s the row.
      expect(partial).to include("<% if attachment.blob.variable? %>")
      expect(partial).to include("resize_to_limit: [ 48, 48 ]")
      expect(partial).to include("number_to_human_size(attachment.blob.byte_size)")
      expect(partial).to include(%(upload_field_action_value: "set_photo"))
      expect(partial).to include("upload_field_dom_value: dom")
      expect(partial).to include("<%= pending[:filename].truncate(12) %> — attaches on save")
      expect(partial).to include("photo removed on save")
      expect(partial).to include("**on(:remove_photo, with: { dom: dom })")
      # The row wraps and the badge sits on its own full-width line AFTER
      # Remove, so a long filename never pushes the button off the row.
      expect(partial).to include(%(<div class="flex flex-wrap items-center gap-3">))
      expect(partial).to include(%(  <div class="w-full">\n    <% if pending&.dig(:remove) %>))
      expect(partial.index("**on(:remove_photo")).to be < partial.index("attaches on save")
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
      expect(row.scan("item.photo_attachment").size).to eq(1)
      expect(row).not_to match(/item\.photo\.\w/)
      expect(row).to include("<% elsif photo_attachment.blob.variable? %>")
      expect(row).to include("resize_to_limit: [ 80, 80 ]")
      expect(row).to include("link_to photo_attachment.blob.filename, rails_blob_path(photo_attachment)")
      expect(row).to include("number_to_human_size(photo_attachment.blob.byte_size)")
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
      expect(form.scan("<% photo_attachment = item.photo_attachment %>").size).to eq(1)
      expect(form).to include("<% if photo_attachment && photo_attachment.blob.variable? %>")
      expect(form).to include("<% elsif photo_attachment %>")
      expect(form.scan("<% if photo_attachment %>").size).to eq(1)
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
      expect(component).to include("include Phlex::Rails::Helpers::NumberToHumanSize")
      expect(component).to include("if attachment.blob.variable?")
      expect(component).to include(%(div(class: "flex flex-wrap items-center gap-3") do))
      expect(component).to include(%(      div(class: "w-full") do\n        if pending&.dig(:remove)))
      expect(component).to include(%({ "\#{pending[:filename].truncate(12)} — attaches on save" }))
      expect(component.index("**on(:remove_photo")).to be < component.index("attaches on save")
      row = generated("app/views/items/row.rb")
      expect(row).to include("photo_attachment = @item.photo_attachment")
      expect(row).to include("elsif photo_attachment.blob.variable?")
      expect(row).to include("link_to(photo_attachment.blob.filename, rails_blob_path(photo_attachment)")
    end

    it "injects the page-form method pair and the helper includes, each once" do
      form = generated("app/views/items/form.rb")
      row = generated("app/views/items/row.rb")

      expect(form.scan("photo_upload_fields(form)").size).to eq(2)
      expect(form).to include("form.file_field :photo, accept: \"image/*\", direct_upload: true")
      expect(form).to include("if photo_attachment && photo_attachment.blob.variable?")
      %w[ImageTag NumberToHumanSize].each do |helper|
        expect(form.scan("include Phlex::Rails::Helpers::#{helper}").size).to eq(1)
        expect(row.scan("include Phlex::Rails::Helpers::#{helper}").size).to eq(1)
      end
      # The scaffold's row already had LinkTo; the guard left it alone.
      expect(row.scan("include Phlex::Rails::Helpers::LinkTo").size).to eq(1)
    end

    it "emits sources that compile and resolve under Zeitwerk" do
      expect_valid_generated_sources(@destination)
      expect_zeitwerk_resolvable_views(@destination)
    end
  end

  describe "--accept" do
    before do
      scaffold
      seed_model
    end

    it "stamps the mapped value on both inputs and skips the thumbnail notice" do
      output = generate(%w[Item document --accept=pdf --css=daisyui])

      expect(generated("app/views/items/_document_upload.html.erb"))
        .to include(%(tag.input type: "file", accept: "application/pdf"))
      expect(generated("app/views/items/_form.html.erb"))
        .to include(%(form.file_field :document, accept: "application/pdf", direct_upload: true))
      # The display still branches — the template is one shape for every
      # accept list.
      expect(generated("app/views/items/_document_upload.html.erb")).to include("attachment.blob.variable?")
      expect(output).not_to include("image_processing")
      expect(output).to include("ActiveStorage.start()")
      expect_valid_generated_sources(@destination)
    end

    it "joins tokens in order, passing a type/subtype or .ext straight through" do
      output = generate(%w[Item document --accept=doc,image,.zip,application/x-foo --css=daisyui])

      expect(generated("app/views/items/_document_upload.html.erb"))
        .to include(%(accept: ".doc,.docx,image/*,.zip,application/x-foo"))
      expect(output).to include("image_processing")
    end

    it "reaches the --phlex pair" do
      scaffold(%w[Item --phlex --css=daisyui])
      generate(%w[Item document --accept=pdf,xls --css=daisyui])

      expect(generated("app/views/items/document_upload.rb")).to include(%(accept: "application/pdf,.xls,.xlsx"))
      expect(generated("app/views/items/form.rb")).to include(%(accept: "application/pdf,.xls,.xlsx"))
      expect_valid_generated_sources(@destination)
    end

    it "refuses an unknown token, writing nothing" do
      output = generate(%w[Item document --accept=pdf,bogus --css=daisyui])

      expect(output).to include(%(unknown --accept token "bogus"))
      expect(exists?("app/channels/concerns/items_channel/document_upload.rb")).to be(false)
      expect(generated("app/models/item.rb")).not_to include("has_one_attached")
    end
  end

  describe "--many" do
    def js_controller = "app/javascript/controllers/upload_field_controller.js"

    def seed_many_model
      write("app/models/item.rb", <<~RUBY)
        class Item < ApplicationRecord
          belongs_to :shelf
          has_many_attached :photos
        end
      RUBY
    end

    describe "on an ERB scaffold" do
      before do
        scaffold
        seed_model
        @output = generate(%w[Item photos --many --css=daisyui])
      end

      it "emits the gallery concern — adds and marks per dom, append + purge at commit" do
        concern = generated("app/channels/concerns/items_channel/photos_upload.rb")

        expect(concern).to include("module ItemsChannel::PhotosUpload")
        expect(concern).to include("included { prepend GraphHooks }")
        expect(concern).to include("@pending_photos = Hibiki::State.new({})")
        expect(concern).to include("def add_photos(data)")
        expect(concern).to include("def remove_photos(data)")
        expect(concern).not_to include("def set_photos")
        # ✕ routes on the payload: a signed_id drops a pending add, an
        # attachment_id toggles a mark — on ids the record actually carries.
        expect(concern).to include('if (signed_id = data["signed_id"].presence)')
        expect(concern).to include('elsif (id = data["attachment_id"].to_i).positive? && ' \
                                   "photos_attachment_ids(form).include?(id)")
        expect(concern).to include("removes.include?(id) ? removes - [ id ] : removes + [ id ]")
        expect(concern).to include("def pending_photos_for(dom)")
        expect(concern).to include("def update_pending_photos(dom, value)")
        expect(concern).to include("def apply_pending_photos(dom, record)")
        # Append, never assign; purge only the marked ids.
        expect(concern).to include("record.photos.attach(*pending[:adds].map { it[:signed_id] }) " \
                                   "if pending[:adds].any?")
        expect(concern).to include("record.photos_attachments.where(id: pending[:removes]).each(&:purge) " \
                                   "if pending[:removes].any?")
        expect(concern).not_to match(/\.photos = /)
        expect(concern.scan(/^\s*(?:locals = )?super$/).size).to eq(5)
        expect(concern.scan("super if defined?(super)").size).to eq(3)
      end

      it "injects has_many_attached and the append/purge virtuals into the model" do
        model = generated("app/models/item.rb")

        expect(model).to include("has_many_attached :photos")
        expect(model).not_to include("has_one_attached")
        expect(model).to include("attribute :add_photos")
        expect(model).to include("attribute :remove_photo_ids, default: -> { [] }")
        # before_save: the record is still dirty there, so attach never
        # recurses into save — and attach appends where photos= replaces.
        expect(model).to include("before_save(if: -> { add_photos.present? }) { photos.attach(*add_photos) }")
        expect(model).to include("after_save(if: -> { remove_photo_ids.present? }) " \
                                 "{ photos_attachments.where(id: remove_photo_ids).each(&:purge) }")
      end

      it "emits the gallery partial: a multiple input, ✕ per file, per-file pending badges" do
        partial = generated("app/views/items/_photos_upload.html.erb")

        expect(partial).to include("<%# locals: (form:, dom:, extras: {}) -%>")
        expect(partial).to include("extras.fetch(:photos_upload, {})[dom] || { adds: [], removes: [] }")
        expect(partial).to include("form.record&.photos_attachments || []")
        expect(partial).to include(%(tag.input type: "file", multiple: true, accept: "image/*"))
        expect(partial).not_to include("file_field_tag")
        expect(partial).to include(%(upload_field_action_value: "add_photos"))
        expect(partial).to include("**on(:remove_photos, with: { dom: dom, attachment_id: attachment.id })")
        expect(partial).to include("**on(:remove_photos, with: { dom: dom, signed_id: add[:signed_id] })")
        expect(partial).to include("<% if pending[:removes].include?(attachment.id) %>")
        expect(partial).to include("removed on save")
        expect(partial).to include("<%= add[:filename].truncate(12) %> — attaches on save")
        expect(partial).to include("<% if attachment.blob.variable? %>")
        # The row wraps; the pending list is its own full-width line after
        # the input.
        expect(partial).to include(%(<div class="flex flex-wrap items-center gap-3">))
        expect(partial).to include(%(<div class="w-full flex flex-wrap gap-2">))
        expect(partial.index("change->upload-field#upload")).to be < partial.index("attaches on save")
      end

      it "renders the partial from the row form and a gallery on the row" do
        row_form = generated("app/views/items/_item_form.html.erb")
        row = generated("app/views/items/_item.html.erb")

        expect(row_form.scan(%(<%= render "items/photos_upload", form: form, dom: dom, extras: extras %>)).size)
          .to eq(1)
        expect(row.scan("item.photos_attachments").size).to eq(1)
        expect(row).not_to match(/item\.photos\.\w/)
        expect(row).to include("<% if photos_attachments.empty? %>")
        expect(row).to include("<% photos_attachments.each do |attachment| %>")
        expect(row).to include("resize_to_limit: [ 80, 80 ]")
        expect(row).to include("link_to attachment.blob.filename, rails_blob_path(attachment)")
      end

      it "extends both strict_loading preloads" do
        expect(generated("app/models/item_query.rb")).to include(".with_attached_photos), page: @page")
        expect(generated("app/channels/item_channel.rb"))
          .to include(".with_attached_photos.strict_loading.find_by(id: record_id)")
      end

      it "injects the classic gallery: a remove checkbox per file and one multiple append field" do
        form = generated("app/views/items/_form.html.erb")

        field = %(form.file_field :add_photos, multiple: true, accept: "image/*", direct_upload: true)
        expect(form.scan(field).size).to eq(1)
        expect(form).not_to include("file_field :photos")
        # multiple + no hidden "": remove_photo_ids stays a clean id list.
        expect(form).to include("form.checkbox :remove_photo_ids, { multiple: true, include_hidden: false, " \
                                'class: "checkbox checkbox-sm" }, attachment.id, nil')
        expect(form).to include("form.label :remove_photo_ids, value: attachment.id")
        expect(form.scan("<% photos_attachments = item.photos_attachments %>").size).to eq(1)
        expect(form.index("form.checkbox :remove_photo_ids")).to be < form.index("file_field :add_photos")
        expect(form.index("file_field :add_photos")).to be < form.index("form.submit")
      end

      it "appends the two arrays to params.expect as a braced group" do
        controller = generated("app/controllers/items_controller.rb")

        expect(controller.scan(", { add_photos: [], remove_photo_ids: [] } ])").size).to eq(1)
        expect(controller).not_to match(/[ ,]:photos\b/)
      end

      it "emits the per-file-looping Stimulus controller and compiling sources" do
        js = generated(js_controller)

        expect(js).to include("for (const file of files)")
        expect(js).to include("performOn(this.element, this.actionValue")
        expect(js).to include(%(if (this.element.multiple) this.element.value = ""))
        expect(@output).not_to include("predates --many")
        expect_valid_generated_sources(@destination)
      end

      it "is idempotent — a re-run changes nothing" do
        before_state = Dir[File.join(@destination, "app/**/*")].to_h { [it, (File.read(it) if File.file?(it))] }
        generate(%w[Item photos --many --css=daisyui])

        after_state = Dir[File.join(@destination, "app/**/*")].to_h { [it, (File.read(it) if File.file?(it))] }
        expect(after_state).to eq(before_state)
      end
    end

    it "selects many-mode from a has_many_attached the model already declares, and says so" do
      scaffold
      seed_many_model
      output = generate(%w[Item photos --css=daisyui])

      expect(output).to include("already declares has_many_attached :photos")
      expect(generated("app/models/item.rb").scan("has_many_attached :photos").size).to eq(1)
      expect(generated("app/models/item.rb")).to include("attribute :add_photos")
      expect(generated("app/channels/concerns/items_channel/photos_upload.rb")).to include("def add_photos(data)")
      expect(generated("app/views/items/_form.html.erb")).to include("file_field :add_photos, multiple: true")
    end

    it "refuses --many against an existing has_one_attached, writing nothing" do
      scaffold
      write("app/models/item.rb",
            "class Item < ApplicationRecord\n  belongs_to :shelf\n  has_one_attached :photo\nend\n")
      output = generate(%w[Item photo --many --css=daisyui])

      expect(output).to include("Item#photo is has_one_attached — run without --many")
      expect(exists?("app/channels/concerns/items_channel/photo_upload.rb")).to be(false)
      expect(exists?(js_controller)).to be(false)
    end

    it "refreshes a pre-many copy of the shared controller — in many-mode only, and once" do
      scaffold
      seed_model
      write(js_controller, "// v1\nconst file = this.element.files[0]\n")

      expect(generate(%w[Item badge --css=daisyui])).to include("identical")
      expect(generated(js_controller)).to include("// v1")

      expect(generate(%w[Item photos --many --css=daisyui])).to include("predates --many")
      expect(generated(js_controller)).to include("for (const file of files)")
      expect(generate(%w[Item photos --many --css=daisyui])).to include("identical")
    end

    it "coexists with a has_one attachment added after it — the scalars still append" do
      scaffold
      seed_model
      generate(%w[Item photos --many --css=daisyui])
      generate(%w[Item cover --css=daisyui])

      expect(generated("app/controllers/items_controller.rb"))
        .to include("{ add_photos: [], remove_photo_ids: [] }, :cover, :remove_cover ])")
      expect(generated("app/models/item_query.rb")).to include(".with_attached_photos.with_attached_cover")
      expect(generated("app/channels/items_channel.rb"))
        .to include("  include Hibiki::Rails::Channel\n  include CoverUpload\n  include PhotosUpload\n")
      expect_valid_generated_sources(@destination)
    end

    it "composes with --accept" do
      scaffold
      seed_model
      output = generate(%w[Item documents --many --accept=pdf --css=daisyui])

      expect(generated("app/views/items/_documents_upload.html.erb"))
        .to include(%(multiple: true, accept: "application/pdf"))
      expect(generated("app/views/items/_form.html.erb"))
        .to include(%(file_field :add_documents, multiple: true, accept: "application/pdf"))
      expect(generated("app/models/item.rb")).to include("attribute :remove_document_ids")
      expect(output).not_to include("image_processing")
    end

    describe "--phlex" do
      before do
        scaffold(%w[Item --phlex --css=daisyui])
        seed_model
        generate(%w[Item photos --many --css=daisyui])
      end

      it "emits the gallery component and the row/form pair, compiling and resolving" do
        component = generated("app/views/items/photos_upload.rb")
        row = generated("app/views/items/row.rb")
        form = generated("app/views/items/form.rb")

        expect(component).to include("class Views::Items::PhotosUpload < Views::Base")
        expect(component).to include("@form.record&.photos_attachments || []")
        expect(component).to include(%(type: "file", multiple: true, accept: "image/*"))
        expect(component).to include("**on(:remove_photos, with: { dom: @dom, attachment_id: attachment.id })) " \
                                     '{ "Undo" }')
        expect(component).to include('**on(:remove_photos, with: { dom: @dom, signed_id: add[:signed_id] })) { "✕" }')
        expect(component).to include(%({ "\#{add[:filename].truncate(12)} — attaches on save" }))
        expect(generated("app/views/items/row_form.rb"))
          .to include("render Views::Items::PhotosUpload.new(form: @form, dom: @dom, extras: @extras)")
        expect(row).to include("photos_attachments = @item.photos_attachments")
        expect(row).to include("photos_attachments.each do |attachment|")
        expect(row).to include("link_to(attachment.blob.filename, rails_blob_path(attachment)")
        expect(form.scan("photos_upload_fields(form)").size).to eq(2)
        expect(form).to include(%(form.file_field :add_photos, multiple: true, accept: "image/*", direct_upload: true))
        expect(form).to include("form.checkbox :remove_photo_ids, { multiple: true, include_hidden: false")
        expect_valid_generated_sources(@destination)
        expect_zeitwerk_resolvable_views(@destination)
      end
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
          generate(["Item", "photos", "--many", *layer, "--css=#{variant}"])

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
