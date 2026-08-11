# frozen_string_literal: true

require "rails/generators"
require "rails/generators/resource_helpers"
require_relative "../generator_helpers"
require_relative "../scaffold_helpers"
require_relative "../scaffold_view_helpers"
require_relative "../scaffold_phlex_helpers"
require_relative "../scaffold_post_install"
require_relative "../scaffold_shared_views"
require_relative "../scaffold_schema"
require_relative "../css_variant"

module Hibiki
  module Rails
    module Generators
      # Re-derives the validator-shaped slice of a scaffolded resource: the
      # ReactiveForm (live_errors) and the two form views (bounds,
      # requiredness). Run it after adding or changing validators on the model;
      # everything else the scaffold wrote is deliberately out of scope, so a
      # customized index or controller is never put at risk over a validator.
      #
      # Always the introspection path: the model and its table must exist,
      # because validators are the one thing this generator is for and only a
      # live model can answer them. A field list is optional and chooses order
      # and subset only — the facts stay the schema's, like the scaffold's own
      # merge.
      class FormGenerator < ::Rails::Generators::NamedBase
        include ::Rails::Generators::ResourceHelpers
        include GeneratorHelpers
        include ScaffoldHelpers
        include ScaffoldViewHelpers
        include ScaffoldPhlexHelpers
        include ScaffoldPostInstall
        include ScaffoldSharedViews

        # The scaffold's templates, reused wholesale — this generator re-emits
        # a subset of that output and must never drift from it. Its own
        # source_root stays beside its own USAGE (Base#usage_path resolves
        # ../USAGE from source_root, and pointing it at the scaffold's tree
        # would serve the scaffold's help text).
        SCAFFOLD_TEMPLATES = File.expand_path("../scaffold_controller/templates", __dir__)

        source_root File.expand_path("templates", __dir__)

        desc "Regenerates a resource's ReactiveForm and form views from the " \
             "model's schema and validators."

        argument :attributes, type: :array, default: [], banner: "field:type field:type"

        class_option :css, type: :string, enum: CssVariant::NAMES,
                           desc: "Markup variant for the form views (default: detect)"
        class_option :skip_views, type: :boolean, default: false,
                                  desc: "Rewrite only the form object — leave the form views alone"
        class_option :phlex, type: :boolean,
                             desc: "Emit Phlex form components (default: detect from existing views)"

        def check_phlex_wiring
          warn_without_phlex_rails unless skip_views?
        end

        # Resolving the schema first means a missing model or an unmigrated
        # table aborts before anything is written.
        def resolve_schema
          schema
          @new_app_dirs = %w[app/forms].reject { exists?(it) }
        end

        def create_form
          template "form.rb.tt", form_path
        end

        def create_views
          return if skip_views?

          if phlex?
            template "views/form.rb.tt", view_path("form.rb")
            template "views/row_form.rb.tt", view_path("row_form.rb")
          else
            template "views/_form.html.erb.tt", view_path("_form.html.erb")
            template "views/_row_form.html.erb.tt", view_path("_#{row_form_partial}.html.erb")
          end

          create_form_shared_views
        end

        def post_install
          restart_notice
          shared_views_notice
          skipped_notice
          live_errors_notice
          uniqueness_notice
        end

        private

        # The same layering as the scaffold's, minus nothing: the css-variant
        # fork holds only the page control today, but an app's own
        # lib/templates override must keep winning first either way.
        def source_paths
          @source_paths ||= [*self.class.source_paths_for_search,
                             *phlex_source_paths,
                             File.join(SCAFFOLD_TEMPLATES, css_variant.to_s),
                             File.join(SCAFFOLD_TEMPLATES, "shared")]
        end

        def phlex_source_paths
          return [] unless phlex?

          [File.join(SCAFFOLD_TEMPLATES, "phlex", css_variant.to_s),
           File.join(SCAFFOLD_TEMPLATES, "phlex", "shared")]
        end

        # Unlike the scaffold pair, the model is REQUIRED on both branches: an
        # argument list here chooses order and subset, never facts, because
        # facts with no validators behind them are exactly the output this
        # generator exists to replace.
        def schema
          @schema ||= if attributes.any?
                        ScaffoldSchema.from_attributes(attributes, model: model_class)
                      else
                        ScaffoldSchema.from_model(model_class)
                      end
        end

        # Aborts rather than emitting a form with nothing derived — like the
        # scaffold's own model_class, but with no field-list escape hatch.
        def model_class
          klass = class_name.safe_constantize
          raise ::Rails::Generators::Error, missing_model_message unless klass

          # Touch the schema here so an unmigrated table fails with our message
          # rather than somewhere inside a template.
          klass.tap(&:columns_hash)
        rescue ::Rails::Generators::Error
          raise
        rescue StandardError
          raise ::Rails::Generators::Error, missing_table_message
        end

        def missing_model_message
          "No model #{class_name}. Generate the resource first:\n    " \
            "bin/rails g hibiki:rails:scaffold #{name} title:string"
        end

        def missing_table_message
          "#{class_name} has no table yet. Run bin/rails db:migrate first"
        end

        def skip_views? = options[:skip_views]

        # Which view layer a previous scaffold left behind. app/views/<res>/
        # form.rb only ever comes from a --phlex run (the ERB layer's file is
        # _form.html.erb), so its presence is the layer answer; --phlex and
        # --no-phlex override for the odd case.
        def phlex?
          return @phlex if defined?(@phlex)

          @phlex = options[:phlex].nil? ? exists?(view_path("form.rb")) : options[:phlex]
        end

        def css_variant
          @css_variant ||= (options[:css] || CssVariant.detect(destination_root)).to_sym
        end

        def css(token) = CssVariant.token(css_variant, token)
        def css? = css_variant != :none
      end
    end
  end
end
