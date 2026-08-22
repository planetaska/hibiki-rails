# frozen_string_literal: true

module Hibiki
  module Rails
    module Generators
      # Naming and preflight for hibiki:rails:upload_field. NamedBase carries
      # the owner; everything attachment-shaped is derived here.
      #
      # The emitted concern's private helpers are attachment-suffixed
      # (update_pending_cover, not update_pending) on purpose: a second run
      # includes a second concern into the same channel, and unsuffixed
      # helpers would override each other with bodies reading different ivars.
      module UploadFieldHelpers
        JS_CONTROLLER = "app/javascript/controllers/upload_field_controller.js"

        # The --accept tokens, css_variant-style: validated against this map,
        # with a raw type/subtype or .ext passing through untouched. Office
        # formats are extension lists because their MIME names are unreadable
        # in a view and browsers honor either form.
        ACCEPT = {
          image: "image/*", audio: "audio/*", video: "video/*",
          pdf: "application/pdf", csv: "text/csv", text: "text/plain",
          doc: ".doc,.docx", xls: ".xls,.xlsx", ppt: ".ppt,.pptx"
        }.freeze

        private

        # ---- --accept --------------------------------------------------------

        def accept_tokens
          tokens = options[:accept].to_s.split(",").map(&:strip).reject(&:empty?)
          tokens.empty? ? ["image"] : tokens
        end

        def accept_value(token)
          return token if token.include?("/") || token.start_with?(".")

          ACCEPT.fetch(token.to_sym) do
            raise ::Rails::Generators::Error,
                  "unknown --accept token #{token.inspect} — expected one of " \
                  "#{ACCEPT.keys.join(', ')}, a type/subtype, or an .ext"
          end
        end

        # The attribute both file inputs carry. Advisory only — the display
        # branches on the blob at render time, and enforcement is the app's.
        def accept_attr
          @accept_attr ||= accept_tokens.flat_map { accept_value(it).split(",") }.uniq.join(",")
        end

        # Thumbnails, and so image_processing, only matter when an image can
        # arrive through the picker at all.
        def image_accepted? = accept_attr.split(",").any? { it.start_with?("image/") }

        # ---- the attachment --------------------------------------------------

        def attachment_name = @attachment_name ||= attachment.underscore
        def attachment_human = attachment_name.humanize

        # The reader that is safe on a frozen row — the bare proxy memoizes
        # into an ivar and raises FrozenError there.
        def attachment_reader = "#{attachment_name}_attachment"
        def with_attached = "with_attached_#{attachment_name}"

        def set_action = "set_#{attachment_name}"
        def remove_action = "remove_#{attachment_name}"
        # Also the model's virtual attribute — one name, two independent
        # mechanisms (channel action / classic checkbox), like the prototype.
        def remove_attr = "remove_#{attachment_name}"

        def extras_key = "#{attachment_name}_upload"

        # ---- the owner -------------------------------------------------------

        def owner_class
          @owner_class ||= begin
            klass = class_name.safe_constantize
            raise ::Rails::Generators::Error, missing_owner_message unless klass

            klass.tap(&:columns_hash)
          rescue ::Rails::Generators::Error
            raise
          rescue StandardError
            raise ::Rails::Generators::Error,
                  "#{class_name} has no table yet. Run bin/rails db:migrate first."
          end
        end

        # The upload rides the scaffold's inline edit form: without the
        # ReactiveForm and the collection channel there is nothing to extend.
        def check_scaffolded!
          missing = [form_path, collection_channel_path].reject { exists?(it) }
          return if missing.empty? && wired?(form_path, /^\s*reactive_attributes\b/)

          raise ::Rails::Generators::Error,
                "#{class_name} is not a hibiki:rails scaffold " \
                "(#{missing.presence&.join(', ') || "#{form_path} has no reactive_attributes"}). " \
                "Run first:\n    bin/rails g hibiki:rails:scaffold_controller #{name}"
        end

        def missing_owner_message
          "No model #{class_name}. hibiki:rails:upload_field extends an existing " \
            "hibiki:rails scaffold — run that first."
        end

        # ---- refusals --------------------------------------------------------

        def check_attachment!
          unless attachment_name.match?(/\A[a-z][a-z0-9_]*\z/)
            raise ::Rails::Generators::Error,
                  "#{attachment.inspect} is not a usable attachment name."
          end

          check_column_collisions!
          check_reflection_collisions!
        end

        def check_column_collisions!
          if owner_class.columns_hash.key?(attachment_name)
            raise ::Rails::Generators::Error,
                  "#{class_name} already has a #{attachment_name} column — " \
                  "an attachment cannot share its name."
          end
          return unless owner_class.columns_hash.key?(remove_attr)

          raise ::Rails::Generators::Error,
                "#{class_name} has a #{remove_attr} column, which the remove " \
                "checkbox needs for its virtual attribute."
        end

        # A same-name has_one_attached does NOT refuse — that is the re-run
        # (or hand-declared) case, and every injection is wired?-guarded.
        def check_reflection_collisions!
          if owner_class.reflect_on_association(attachment_name.to_sym)
            raise ::Rails::Generators::Error,
                  "#{class_name}##{attachment_name} is already an association."
          end
          return unless many_attached?

          raise ::Rails::Generators::Error,
                "#{class_name}##{attachment_name} is has_many_attached — " \
                "hibiki:rails:upload_field only supports has_one_attached."
        end

        # respond_to? guarded: Active Storage may not be loaded where the
        # generator runs (the spec dummy loads ActiveRecord alone).
        def many_attached?
          return false unless owner_class.respond_to?(:attachment_reflections)

          owner_class.attachment_reflections[attachment_name]&.macro == :has_many_attached
        end

        # ---- the emitted names -----------------------------------------------

        def concern_name = "#{attachment_name.camelize}Upload"
        def concern_module_name = "#{collection_channel_class_name}::#{concern_name}"

        def concern_path
          File.join("app/channels/concerns", "#{controller_file_path}_channel",
                    "#{attachment_name}_upload.rb")
        end

        def upload_partial = "#{attachment_name}_upload"
        def component_class_name = view_class_name(:"#{attachment_name}_upload")

        def page_form_view = phlex? ? view_path("form.rb") : view_path("_form.html.erb")

        # ---- emitting css ----------------------------------------------------

        # `, class: "…"` in argument position, or nothing at all — the
        # argument-list twin of css_attr.
        def arg_css(token)
          value = css(token)
          value ? %(, class: "#{value}") : ""
        end
      end
    end
  end
end
