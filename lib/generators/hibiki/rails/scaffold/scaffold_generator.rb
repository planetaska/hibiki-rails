# frozen_string_literal: true

require "rails/generators"
require "rails/generators/rails/resource/resource_generator"
require_relative "../scaffold_helpers"
require_relative "../css_variant"
require_relative "../scaffold_controller/scaffold_controller_generator"

module Hibiki
  module Rails
    module Generators
      # The headline command: model + migration + route + a reactive CRUD
      # resource, the way `rails g scaffold` emits a plain one.
      #
      # Subclasses Rails' ResourceGenerator, which is the model generator plus
      # the resource_route hook — so the model, its migration, its fixtures and
      # the route all come from Rails itself, unchanged. Only the controller
      # half is ours.
      #
      # Stock `rails g scaffold` is deliberately left alone: this lives under
      # its own namespace and nothing here registers as Rails' scaffold_controller.
      class ScaffoldGenerator < ::Rails::Generators::ResourceGenerator
        include ScaffoldHelpers

        remove_hook_for :resource_controller
        remove_class_option :actions

        # ResourceGenerator overrides .desc to read usage_path UNCONDITIONALLY —
        # unlike Base.desc, which falls back when there is none. So this
        # generator needs both a source_root (whose parent holds USAGE) and a
        # USAGE file that actually ships, or `bin/rails g` raises TypeError
        # while merely LISTING generators. The gemspec globs USAGE for exactly
        # this reason.
        source_root File.expand_path("templates", __dir__)

        # Re-declared so `--help` lists them and Thor validates the enum here
        # rather than one generator later; they propagate to the controller
        # generator as raw switches.
        class_option :css, type: :string, enum: CssVariant::NAMES,
                           desc: "Markup variant for every generated view (default: detect)"
        class_option :infinite_scroll, type: :boolean, default: false,
                                       desc: "Grow the window on scroll instead of numbering pages"
        class_option :skip_pagination, type: :boolean, default: false,
                                       desc: "No windowing at all — skips both pagination modes"
        class_option :skip_search, type: :boolean, default: false,
                                   desc: "Omit the search box and the LIKE terms behind it"
        class_option :page_size, type: :numeric, default: 20, desc: "Rows per page"

        def initialize(...)
          super
          return if attributes.any?

          # Raised HERE rather than in a task, because the inherited orm hook
          # runs first and would otherwise write a model and a migration before
          # the controller generator discovered it had nothing to work from.
          raise ::Rails::Generators::Error, <<~MESSAGE.strip
            #{self.class.banner} needs at least one field — the migration has not run when the
            views are generated, so the schema cannot be read yet. For a model that
            already exists, use:

                bin/rails g hibiki:rails:scaffold_controller #{name}
          MESSAGE
        end

        def invoke_hibiki_scaffold_controller
          # to_argv, never GeneratedAttribute#to_s: `title:string!` round-trips
          # through to_s as "title:string{null}", which .parse then rejects.
          invoke ScaffoldControllerGenerator, [name, *attributes.map { to_argv(it) }]
        end
      end
    end
  end
end
