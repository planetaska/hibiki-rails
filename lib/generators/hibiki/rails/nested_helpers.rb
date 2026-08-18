# frozen_string_literal: true

module Hibiki
  module Rails
    module Generators
      # Naming, mode detection and preflight for hibiki:rails:nested. The
      # generator takes two names — parent and child — plus an optional field
      # list; NamedBase carries only the parent, so everything child-shaped is
      # derived here.
      #
      # Two modes, decided from what is on disk:
      #
      #   root  the parent is a scaffolded resource — the fieldset goes into
      #         its row form, the params.expect group into its controller.
      #   deep  the parent is itself a nested child (its _<parent>_fields
      #         partial exists somewhere under app/views) — the fieldset nests
      #         into that partial and every other injection walks up to the
      #         resource that owns it. Depth is composition: one run per edge.
      module NestedHelpers
        private

        # ---- child -----------------------------------------------------------

        # classify, so a plural argument ("Credits") lands on the same class
        # as the singular.
        def child_class_name = @child_class_name ||= child.classify

        def child_singular = @child_singular ||= child_class_name.demodulize.underscore
        def child_plural = @child_plural ||= child_singular.pluralize
        def child_human_singular = child_singular.humanize
        def child_human_plural = child_plural.humanize

        # The has_many on the parent, and the key to_h serializes it under.
        def association_name = child_plural
        def attributes_key = "#{child_plural}_attributes"

        def child_form_class_name = "#{child_class_name}Form"
        def child_form_path = File.join("app/forms", "#{child_class_name.underscore}_form.rb")
        def child_model_path = File.join("app/models", "#{child_class_name.underscore}.rb")
        def child_table_name = child_class_name.tableize.tr("/", "_")

        # Create mode: no constant, no model file, and a field list to build
        # from. Memoized before the invoke writes the file — later calls must
        # keep the preflight answer.
        def create_child?
          return @create_child if defined?(@create_child)

          @create_child = attributes.any? && child_class_name.safe_constantize.nil? &&
                          !exists?(child_model_path)
        end

        def child_class
          @child_class ||= begin
            klass = child_class_name.safe_constantize
            raise ::Rails::Generators::Error, missing_child_message unless klass

            klass.tap(&:columns_hash)
          rescue ::Rails::Generators::Error
            raise
          rescue StandardError
            raise ::Rails::Generators::Error,
                  "#{child_class_name} has no table yet. Run bin/rails db:migrate first."
          end
        end

        def missing_child_message
          if exists?(child_model_path)
            "#{child_class_name} has no table yet. Run bin/rails db:migrate first."
          else
            "No model #{child_class_name}. Pass its fields and the generator creates it " \
              "(#{singular_name}:references is added for you):\n    " \
              "bin/rails g hibiki:rails:nested #{name} #{child} role:string"
          end
        end

        # The child's belongs_to back to the parent. Required: the has_many's
        # inverse_of and accepts_nested_attributes_for both stand on it, and
        # `bin/rails g model Child parent:references` declares it anyway.
        def parent_reflection
          @parent_reflection ||= child_class.reflect_on_association(singular_name.to_sym).tap do |reflection|
            unless reflection&.macro == :belongs_to
              raise ::Rails::Generators::Error,
                    "#{child_class_name} must declare belongs_to :#{singular_name}. " \
                    "Add it, migrate, then re-run."
            end
          end
        end

        # ---- mode ------------------------------------------------------------

        # A collection channel only ever comes from the scaffold, so its
        # presence is the root-mode answer.
        def root_mode?
          return @root_mode if defined?(@root_mode)

          @root_mode = exists?(collection_channel_path)
        end

        # Where the parent's own fields partial lives — the deep-mode
        # discovery, and the file the fieldset nests into.
        def parent_fields_files
          @parent_fields_files ||= Dir[
            File.join(destination_root, "app/views/**/_#{singular_name}_fields.html.erb"),
            File.join(destination_root, "app/views/**/#{singular_name}_fields.rb")
          ].map { it.delete_prefix("#{destination_root}/") }
        end

        # Everything that can refuse, before anything is written.
        def check_wireable!
          if create_child?
            check_parent_wireable!
            check_creatable!
          else
            child_class
            parent_reflection
            check_parent_wireable!
          end
          check_editable_columns!
        end

        def check_parent_wireable!
          raise ::Rails::Generators::Error, unwireable_parent_message if !root_mode? && parent_fields_files.empty?
          return if exists?(form_path) && wired?(form_path, /^\s*reactive_attributes\b/)

          raise ::Rails::Generators::Error,
                "#{form_path} is missing or has no reactive_attributes — " \
                "run first:\n    bin/rails g hibiki:rails:scaffold_controller #{name}"
        end

        def unwireable_parent_message
          "#{class_name} is neither a hibiki:rails scaffold (no " \
            "#{collection_channel_path}) nor a nested child (no " \
            "_#{singular_name}_fields partial). Scaffold it — or generate " \
            "the parent's own edge first."
        end

        def check_editable_columns!
          return unless schema.empty?

          raise ::Rails::Generators::Error,
                "#{child_class_name} has no editable columns beyond " \
                "#{child_foreign_key}#{" and #{position_column}" if ordered?} — " \
                "nothing to build a fieldset from."
        end

        # A bare <parent>_id column generates no belongs_to, and the has_many's
        # inverse_of and accepts_nested_attributes_for both stand on it.
        def check_creatable!
          fk = "#{singular_name}_id"
          return if attributes.none? { !it.reference? && it.name == fk }

          raise ::Rails::Generators::Error,
                "Spell the parent column #{singular_name}:references — a bare #{fk} " \
                "generates no belongs_to, and the nested wiring needs one."
        end

        # ---- the owning resource ---------------------------------------------
        #
        # Root mode: the parent itself. Deep mode: derived from where the
        # parent's fields partial sits — app/views/admin/songs/_credit_fields
        # names admin/songs, and the channel, controller and page form follow.

        def parent_fields_view
          @parent_fields_view ||= parent_fields_files.find do |path|
            phlex? ? path.end_with?(".rb") : path.end_with?(".html.erb")
          end
        end

        def resource_view_dir
          @resource_view_dir ||= root_mode? ? view_dir : File.dirname(parent_fields_view)
        end

        def resource_path = @resource_path ||= resource_view_dir.delete_prefix("app/views/")
        def resource_singular = @resource_singular ||= resource_path.split("/").last.singularize
        def resource_class_name = @resource_class_name ||= root_mode? ? class_name : resource_path.classify

        def resource_channel_path
          root_mode? ? collection_channel_path : File.join("app/channels", "#{resource_path}_channel.rb")
        end

        def resource_controller_path
          root_mode? ? scaffold_controller_path : File.join("app/controllers", "#{resource_path}_controller.rb")
        end

        def resource_view(basename) = File.join(resource_view_dir, basename)

        def list_view = resource_view(phlex? ? "list.rb" : "_list.html.erb")
        def row_view = resource_view(phlex? ? "row.rb" : "_#{resource_singular}.html.erb")

        def row_form_view
          resource_view(phlex? ? "row_form.rb" : "_#{resource_singular}_form.html.erb")
        end

        def page_form_view = resource_view(phlex? ? "form.rb" : "_form.html.erb")

        # Where the child's fieldset render is injected: the row form at the
        # root, the parent's own fields partial any deeper.
        def container_view
          return row_form_view if root_mode?

          resource_view(phlex? ? "#{singular_name}_fields.rb" : "_#{singular_name}_fields.html.erb")
        end

        def fields_view_target
          resource_view(phlex? ? "#{child_singular}_fields.rb" : "_#{child_singular}_fields.html.erb")
        end

        def resource_views_module
          "Views::#{resource_path.split('/').map(&:camelize).join('::')}"
        end

        def fields_component_class_name = "#{resource_views_module}::#{child_singular.camelize}Fields"

        # ---- the child schema ------------------------------------------------
        #
        # Introspection when the child model exists (the scaffold's 3.6 merge
        # when a field list narrows or orders it); the argument-only path when
        # this run is creating the model — the fresh constant is not loadable
        # in-process, so nothing may read it. The parent's foreign key and the
        # ordering column never become form fields: the association assigns
        # one, the parent form stamps the other.

        def introspectable_child = create_child? ? nil : child_class

        # Argument-derived in create mode: there is no reflection to ask yet.
        def child_foreign_key
          @child_foreign_key ||= create_child? ? "#{singular_name}_id" : parent_reflection.foreign_key.to_s
        end

        # What create_child_model hands to active_record:model: the parent
        # reference prepended unless the field list already spells it, the
        # --position column appended when ordering asked for one the list
        # doesn't carry.
        def child_model_argv
          parent_ref = ("#{singular_name}:references" unless parent_ref_argument?)
          position_arg = ("#{position_column}:integer" if ordered? && options[:position].present? &&
                                                          attributes.none? { it.name == position_column })
          [child_class_name, *parent_ref, *attributes.map { to_argv(it) }, *position_arg]
        end

        def parent_ref_argument? = attributes.any? { it.reference? && it.name == singular_name }

        def full_schema
          @full_schema ||= if attributes.any?
                             ScaffoldSchema.from_attributes(attributes, model: introspectable_child)
                           else
                             ScaffoldSchema.from_model(child_class)
                           end
        end

        def schema
          @schema ||= ScaffoldSchema.new(columns: form_columns)
        end

        def form_columns
          full_schema.columns.reject { form_excluded?(it) }
        end

        def form_excluded?(column)
          return true if column.belongs_to? && column.association_name == singular_name.to_sym
          return true if column.name.to_s == child_foreign_key

          ordered? && column.name.to_s == position_column
        end

        # ---- ordering --------------------------------------------------------

        def ordered?
          return @ordered if defined?(@ordered)

          @ordered = if options[:skip_position] then false
                     elsif options[:position].present? then true
                     elsif create_child? then attributes.any? { it.name == "position" }
                     else child_class.column_names.include?("position")
                     end
        end

        def position_column = @position_column ||= options[:position].presence || "position"

        def position_migration_needed?
          ordered? && !create_child? && !child_class.column_names.include?(position_column)
        end

        # ---- template refs ---------------------------------------------------
        #
        # How the fields template refers to what it was handed, per view
        # layer: a partial gets locals, a component ivars. dom_ref and
        # options_ref come from ScaffoldViewHelpers unchanged.

        def nested_record_ref = phlex? ? "@#{child_singular}" : child_singular
        def nested_path_ref = phlex? ? "@path" : "path"
        def nested_index_ref = phlex? ? "@index" : "index"
        def nested_count_ref = phlex? ? "@count" : "count"

        # What holds the child array inside the container: the parent form at
        # the root, the parent's own child form one level down.
        def parent_form_ref
          if root_mode?
            phlex? ? "@form" : "form"
          else
            phlex? ? "@#{singular_name}" : singular_name
          end
        end

        # Runtime path sources: root rows address from the top
        # ("credits/<key>"); deeper rows grow the parent's own path.
        def collection_path_source
          root_mode? ? %("#{child_plural}") : %("\#{#{nested_container_path_ref}}/#{child_plural}")
        end

        def child_path_source(var)
          if root_mode?
            %("#{child_plural}/\#{#{var}.nested_key}")
          else
            %("\#{#{nested_container_path_ref}}/#{child_plural}/\#{#{var}.nested_key}")
          end
        end

        # The CONTAINER's own path local/ivar (deep mode only).
        def nested_container_path_ref = phlex? ? "@path" : "path"

        # The fields_for builder variables in the classic page form.
        def fallback_builder_var = "#{child_singular}_form"
        def parent_builder_var = root_mode? ? "form" : "#{singular_name}_form"

        # ---- arg builders (both view layers) ---------------------------------

        # Plain strings, not %() — the parens are deliberately unbalanced
        # inside each half.
        def nested_on_args(column)
          "**on(:nested_set_field, event: :#{column.tag_event}, " \
            "with: { dom: #{dom_ref}, path: #{nested_path_ref}, field: \"#{column.name}\" })"
        end

        def nested_field_args(column)
          bounds = html_bounds_source(column)

          [%("\#{#{nested_path_ref}}/#{column.name}"), "#{nested_record_ref}.#{column.name}",
           *(bounds unless bounds.empty?),
           %(id: "\#{dom_path}_#{column.name}"),
           *css_args(row_field_token(column)),
           nested_on_args(column)]
        end

        def nested_toggle_args(column)
          [%("\#{#{nested_path_ref}}/#{column.name}"), %("1"), "#{nested_record_ref}.#{column.name}",
           %(id: "\#{dom_path}_#{column.name}"),
           *css_args(:toggle),
           nested_on_args(column)]
        end

        def nested_select_head_args(column)
          [%("\#{#{nested_path_ref}}/#{column.name}"),
           %(include_blank: "Select #{column.human_name.downcase}"),
           %(id: "\#{dom_path}_#{column.name}"),
           *css_args(row_field_token(column)),
           nested_on_args(column)]
        end

        def nested_select_options_source(column)
          "options_for_select(#{options_ref(column)}, #{nested_record_ref}.#{column.name})"
        end

        def nested_select_args(column)
          head, *tail = nested_select_head_args(column)

          [head, nested_select_options_source(column), *tail]
        end

        def nested_move_args(direction)
          to = "#{nested_index_ref} #{direction == :up ? '-' : '+'} 1"

          [%(type: "button"),
           *css_args(:btn_ghost_sm),
           %("aria-label": "Move #{child_human_singular.downcase} #{direction}"),
           %(**on(:nested_move, with: { dom: #{dom_ref}, path: #{nested_path_ref}, to: #{to} }))]
        end
      end
    end
  end
end
