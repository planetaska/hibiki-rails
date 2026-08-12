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
require_relative "../multiselect_helpers"
require_relative "../multiselect_injections"

module Hibiki
  module Rails
    module Generators
      # A dropdown multi-select over a has_many :through, added onto a
      # resource hibiki:rails:scaffold_controller already generated: a channel
      # concern that wraps the graph (the include line is the channel's only
      # edit), a view partial or component riding the extras: hash, an ids
      # signal on the ReactiveForm, and the join model when it doesn't exist
      # yet.
      #
      # Owner and target must exist and be migrated; the join is the one model
      # this generator may create.
      class MultiselectGenerator < ::Rails::Generators::NamedBase
        include ::Rails::Generators::ResourceHelpers
        include ::ActiveRecord::Generators::Migration
        include GeneratorHelpers
        include ScaffoldHelpers
        include ScaffoldViewHelpers
        include ScaffoldPhlexHelpers
        include ScaffoldModelInjection
        include MultiselectHelpers
        include MultiselectInjections

        source_root File.expand_path("templates", __dir__)

        desc "Adds a dropdown multi-select for a has_many :through onto a " \
             "hibiki:rails scaffold, generating the join model if needed."

        argument :target, type: :string, banner: "Target"
        argument :join, type: :string, required: false, default: nil, banner: "[Join]"

        class_option :css, type: :string, enum: CssVariant::NAMES,
                           desc: "Markup variant for the generated view (default: detect)"
        class_option :skip_search, type: :boolean, default: false,
                                   desc: "No filter input — also drops the option limit, " \
                                         "which would strand options it hides"
        class_option :limit, type: :numeric, default: 50,
                             desc: "How many options the dropdown offers at once"
        class_option :label, type: :string,
                             desc: "The target column shown per option (default: infer)"
        class_option :phlex, type: :boolean,
                             desc: "Emit a Phlex component (default: detect from the scaffold)"

        # Everything that can refuse, before anything is written.
        def preflight
          owner_class
          target_class
          check_scaffolded!
          label_column
          join_class_name
          @concerns_dir_new = !exists?("app/channels/concerns")
        end

        def create_join_model
          return unless (@join_generated = join_missing?)

          template "join_model.rb.tt", join_model_path
          migration_template "join_migration.rb.tt", "db/migrate/create_#{join_table_name}.rb"
        end

        def wire_models
          inject_owner_associations
          inject_join_touch
        end

        def create_concern
          template "concern.rb.tt", concern_path
        end

        def wire_channel
          inject_channel_include
        end

        def wire_form
          inject_form_association
        end

        def create_view
          if phlex?
            template "multiselect_component.rb.tt", view_path("#{multiselect_partial}.rb")
          else
            template "_multiselect.html.erb.tt", view_path("_#{multiselect_partial}.html.erb")
          end
        end

        # BEFORE the render injection: the compat probe reads "extras" from the
        # row form, and the render line would satisfy it vacuously.
        def thread_extras
          thread_extras_through_partials
        end

        def wire_views
          inject_row_form_render
          inject_row_display
        end

        def wire_preloads
          inject_query_preload
          inject_member_channel_preload
        end

        def post_install
          if @join_generated
            say_status :migrate, "#{join_class_name} was generated — run bin/rails db:migrate " \
                                 "before using the multiselect.", :yellow
          end
          if @concerns_dir_new
            say_status :restart, "app/channels/concerns is new. " \
                                 "Please restart if the server is running.", :yellow
          end
          say_status :assoc, "using #{target_class_name}##{label_column} as the option label — " \
                             "pass --label=<column> if that's wrong", :blue
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
      end
    end
  end
end
