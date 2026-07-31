# frozen_string_literal: true

require "rails/generators"

module Hibiki
  module Rails
    module Generators
      # Shared naming and wiring-detection helpers for the hibiki:rails:*
      # generators. The naming helpers ride on NamedBase's name parts
      # (regular_class_path / file_name); the wiring predicates only need
      # destination_root, so the install generator uses them too.
      module GeneratorHelpers
        INDEX_JS = "app/javascript/controllers/index.js"
        SHIM = "app/javascript/controllers/hibiki_controller.js"
        APPLICATION_HELPER = "app/helpers/application_helper.rb"
        REGISTER_FRAGMENT = 'application.register("hibiki"'
        IMPORTMAP = "config/importmap.rb"

        private

        # First streamable of the concern's [channel_name, cid] convention:
        # ActionCable's channel_name for Admin::CounterChannel is
        # "admin:counter".
        def stream_name = name_parts.join(":")

        # The Stimulus identifier Rails derives from
        # app/javascript/controllers/<file_path>_controller.js.
        def identifier = name_parts.join("--").tr("_", "-")

        # Root id of the replaced fragment — namespaced with the component's
        # own name so several generated islands can share a page.
        def display_dom_id = "#{name_parts.join('_')}_display"

        def nested? = !regular_class_path.empty?

        def name_parts = regular_class_path + [file_name]

        # The install generator's file-backed shim is the wiring artifact;
        # the index.js fragment covers hand-wired (or pre-shim) apps.
        def hibiki_registered? = exists?(SHIM) || wired?(INDEX_JS, REGISTER_FRAGMENT)

        def helpers_included? = wired?(APPLICATION_HELPER, "Hibiki::Rails::Helpers")

        # importmap-rails apps eager-load the controllers directory;
        # jsbundling apps register each controller in index.js by hand.
        def importmap? = exists?(IMPORTMAP)

        def exists?(path) = File.exist?(File.join(destination_root, path))

        # A String fragment is a substring test; a Regexp is matched. The
        # Regexp form exists because a substring is the wrong test whenever the
        # fragment is a Ruby declaration rather than a constant: "has_many
        # :books" is contained in "has_many :books_on_loan", and reading that
        # as "already wired" is a silent wrong answer.
        def wired?(path, fragment)
          full = File.join(destination_root, path)
          return false unless File.exist?(full)

          content = File.read(full)
          fragment.is_a?(Regexp) ? content.match?(fragment) : content.include?(fragment)
        end

        def manual_wiring(path, snippet)
          say_status :skip, "#{path} not found — add this yourself:", :yellow
          say snippet
        end

        # Shared by every generator that emits an island: without the register
        # line and the Helpers include, the markup is present and inert, with
        # no error anywhere.
        def wiring_hint
          return if hibiki_registered? && helpers_included?

          say_status :hint, "the packaged client is not fully wired " \
                            "(register line and/or Helpers include) — run: " \
                            "bin/rails g hibiki:rails:install", :yellow
        end
      end
    end
  end
end
