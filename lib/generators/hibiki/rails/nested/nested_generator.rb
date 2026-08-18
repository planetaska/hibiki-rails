# frozen_string_literal: true

require "rails/generators"
require "rails/generators/resource_helpers"
require "rails/generators/active_record"
require_relative "../generator_helpers"
require_relative "../scaffold_helpers"
require_relative "../scaffold_view_helpers"
require_relative "../scaffold_phlex_helpers"
require_relative "../scaffold_model_injection"
require_relative "../scaffold_schema"
require_relative "../css_variant"
require_relative "../nested_helpers"
require_relative "../nested_injections"

module Hibiki
  module Rails
    module Generators
      # One parent→child edge of a nested form, onto a resource
      # hibiki:rails:scaffold_controller already generated: the child's
      # ReactiveForm and fields partial (path-addressed inputs riding the
      # generic Hibiki::Rails::NestedActions), reactive_nested on the parent
      # form, the model wiring, the classic fields_for fallback in the
      # full-page form, and the controller's params.expect double-array group.
      # A missing child model is created from the field list (model +
      # migration via active_record:model, the parent reference prepended).
      #
      # Depth is composition — run once per edge. A run whose parent is
      # itself a nested child injects into the parent's own fields partial
      # instead of the row form, and nests every other wiring one level
      # deeper.
      class NestedGenerator < ::Rails::Generators::NamedBase
        include ::Rails::Generators::ResourceHelpers
        include ::ActiveRecord::Generators::Migration
        include GeneratorHelpers
        include ScaffoldHelpers
        include ScaffoldViewHelpers
        include ScaffoldPhlexHelpers
        include ScaffoldModelInjection
        include NestedHelpers
        include NestedInjections

        source_root File.expand_path("templates", __dir__)

        desc "Wires one parent→child edge of a nested form (reactive_nested " \
             "+ the generic nested_* actions) onto a hibiki:rails scaffold."

        argument :child, type: :string, banner: "Child"
        argument :attributes, type: :array, default: [], banner: "field[:type] field[:type]"

        class_option :css, type: :string, enum: CssVariant::NAMES,
                           desc: "Markup variant for the generated view (default: detect)"
        class_option :position, type: :string,
                                desc: "Order the rows by this child column — added by migration " \
                                      "when missing (default: a column named position, when present)"
        class_option :skip_position, type: :boolean, default: false,
                                     desc: "No ordering, even when the child has a position column"
        class_option :phlex, type: :boolean,
                             desc: "Emit a Phlex fields component (default: detect from the scaffold)"

        # Everything that can refuse, before anything is written.
        def preflight
          check_wireable!
          warn_without_phlex_rails
        end

        def create_child_model
          return unless create_child?

          # to_argv, never GeneratedAttribute#to_s: `title:string!` round-trips
          # through to_s as "title:string{null}", which .parse then rejects.
          invoke "active_record:model", child_model_argv
        end

        def create_child_form
          template "child_form.rb.tt", child_form_path
        end

        def create_fields_view
          if phlex?
            template "fields_component.rb.tt", fields_view_target
          else
            template "_fields.html.erb.tt", fields_view_target
          end
        end

        def create_position_migration
          return unless (@position_migration = position_migration_needed?)

          migration_template "position_migration.rb.tt",
                             "db/migrate/add_#{position_column}_to_#{child_table_name}.rb"
        end

        def wire_model
          inject_parent_model
        end

        def wire_form
          inject_form_nested
        end

        # BEFORE the fieldset injection: the threading guards probe for each
        # options local's name, and the injected render line would satisfy
        # them vacuously.
        def wire_channel
          inject_channel_include
          inject_edit_preload
          inject_option_collections
        end

        def wire_views
          inject_container_fieldset
        end

        def wire_page_form
          inject_page_form
        end

        def wire_controller
          inject_permitted_params
        end

        def post_install
          migrate_notice
          schema.belongs_tos.each do |column|
            say_status :assoc, "using #{column.association_class_name}##{column.label_column} as " \
                               "the #{column.human_name.downcase} option label — edit " \
                               "@#{column.options_local} in #{resource_channel_path} if that's wrong", :blue
          end
        end

        private

        # Never both: a created child's ordering column rides its
        # create-table migration.
        def migrate_notice
          if create_child?
            say_status :migrate, "#{child_class_name} was generated — " \
                                 "run bin/rails db:migrate before using the fieldset.", :yellow
          elsif @position_migration
            say_status :migrate, "#{child_table_name}.#{position_column} was added — " \
                                 "run bin/rails db:migrate before using the fieldset.", :yellow
          end
        end

        # The scaffold's own view layer, read from what it left on disk; an
        # explicit --phlex wins. Deep mode reads it off the parent's fields
        # partial instead of the row form.
        def phlex?
          return @phlex if defined?(@phlex)

          @phlex = if !options[:phlex].nil?
                     options[:phlex]
                   elsif root_mode?
                     exists?(view_path("row_form.rb"))
                   else
                     parent_fields_files.any? { it.end_with?(".rb") } &&
                       parent_fields_files.none? { it.end_with?(".html.erb") }
                   end
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
