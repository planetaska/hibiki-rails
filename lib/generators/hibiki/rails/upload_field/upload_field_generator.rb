# frozen_string_literal: true

require "rails/generators"
require "rails/generators/resource_helpers"
require_relative "../generator_helpers"
require_relative "../scaffold_helpers"
require_relative "../scaffold_view_helpers"
require_relative "../scaffold_phlex_helpers"
require_relative "../scaffold_model_injection"
require_relative "../css_variant"
require_relative "../extras_threading"
require_relative "../upload_field_helpers"
require_relative "../upload_field_injections"

module Hibiki
  module Rails
    module Generators
      # A has_one_attached upload on both edit surfaces of a resource
      # hibiki:rails:scaffold_controller already generated. The classic form
      # gets a direct-upload file field plus a remove checkbox; the inline
      # channel form gets an upload-on-change input whose pending state the
      # graph owns, keyed by the form's dom — only the signed blob id ever
      # rides the channel.
      #
      # The owner must exist and be migrated; one attachment per run.
      class UploadFieldGenerator < ::Rails::Generators::NamedBase
        include ::Rails::Generators::ResourceHelpers
        include GeneratorHelpers
        include ScaffoldHelpers
        include ScaffoldViewHelpers
        include ScaffoldPhlexHelpers
        include ScaffoldModelInjection
        include ExtrasThreading
        include UploadFieldHelpers
        include UploadFieldInjections

        source_root File.expand_path("templates", __dir__)

        desc "Adds a has_one_attached upload onto a hibiki:rails scaffold: " \
             "direct upload on the classic form, upload-on-change with " \
             "graph-owned pending state on the inline form."

        argument :attachment, type: :string, banner: "Attachment"

        class_option :css, type: :string, enum: CssVariant::NAMES,
                           desc: "Markup variant for the generated view (default: detect)"
        class_option :phlex, type: :boolean,
                             desc: "Emit a Phlex component (default: detect from the scaffold)"

        # Everything that can refuse, before anything is written.
        def preflight
          owner_class
          check_scaffolded!
          check_attachment!
          @concerns_dir_new = !exists?("app/channels/concerns")
        end

        def create_concern
          template "concern.rb.tt", concern_path
        end

        # ONE controller file per app — every upload field shares it, routed
        # by the action/dom Stimulus values the view stamps on the input.
        def create_stimulus_controller
          return say_status :identical, JS_CONTROLLER, :blue if exists?(JS_CONTROLLER)

          template "upload_field_controller.js.tt", JS_CONTROLLER
        end

        # Importmap apps eager-load the controllers directory; jsbundling apps
        # get the import/register pair (stimulus:manifest:update format).
        def register_stimulus_controller
          return if importmap?
          return say_status :identical, INDEX_JS, :blue if wired?(INDEX_JS, %(register("upload-field")))
          return manual_wiring(INDEX_JS, js_registration) unless exists?(INDEX_JS)

          append_to_file INDEX_JS, "\n#{js_registration}"
        end

        def create_view
          if phlex?
            template "upload_component.rb.tt", view_path("#{upload_partial}.rb")
          else
            template "_upload.html.erb.tt", view_path("_#{upload_partial}.html.erb")
          end
        end

        # BEFORE the render injection: the compat probe reads "extras" from the
        # row form, and the render line would satisfy it vacuously.
        def thread_extras
          thread_extras_through_partials
        end

        def wire_channel
          inject_channel_include
        end

        def wire_model
          inject_model_attachment
        end

        def wire_views
          inject_row_form_render
          inject_row_display
        end

        def wire_preloads
          inject_query_preload
          inject_member_channel_preload
        end

        def wire_page_form
          inject_page_form
        end

        def wire_controller
          inject_permitted_params
        end

        def post_install
          unless active_storage_ready?
            say_status :migrate, "no Active Storage tables — run bin/rails active_storage:install " \
                                 "and bin/rails db:migrate before uploading.", :yellow
          end
          unless wired?("Gemfile", /^\s*gem ["']image_processing/)
            say_status :gem, "thumbnails need image_processing — uncomment it in the Gemfile " \
                             "and bundle install.", :yellow
          end
          importmap_notice
          unless wired?("app/javascript/application.js", "activestorage")
            say_status :js, "the classic form needs Active Storage started in " \
                            "app/javascript/application.js: " \
                            'import * as ActiveStorage from "@rails/activestorage"; ' \
                            "ActiveStorage.start()", :yellow
          end
          return unless @concerns_dir_new

          say_status :restart, "app/channels/concerns is new. " \
                               "Please restart if the server is running.", :yellow
        end

        private

        # The scaffold's own view layer, read from what it left on disk; an
        # explicit --phlex wins.
        def phlex?
          return options[:phlex] unless options[:phlex].nil?

          @phlex ||= exists?(view_path("row_form.rb"))
        end

        def css_variant
          @css_variant ||= (options[:css] || CssVariant.detect(destination_root)).to_sym
        end

        def css(token) = CssVariant.token(css_variant, token)
        def css? = css_variant != :none

        def js_registration
          <<~JS
            import UploadFieldController from "./upload_field_controller"
            application.register("upload-field", UploadFieldController)
          JS
        end

        def active_storage_ready?
          ::ActiveRecord::Base.connection_pool.with_connection do |connection|
            connection.data_source_exists?("active_storage_blobs")
          end
        rescue StandardError
          false
        end

        def importmap_notice
          return unless importmap?
          return if wired?(IMPORTMAP, "@rails/activestorage")

          say_status :importmap, "pin the uploader in config/importmap.rb: " \
                                 'pin "@rails/activestorage", to: "activestorage.esm.js"', :yellow
        end
      end
    end
  end
end
