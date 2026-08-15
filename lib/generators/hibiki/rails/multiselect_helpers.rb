# frozen_string_literal: true

module Hibiki
  module Rails
    module Generators
      # Naming and preflight for hibiki:rails:multiselect. The generator takes
      # three names — owner, target, join — and NamedBase only ever carries the
      # first, so everything target- and join-shaped is derived here.
      module MultiselectHelpers
        private

        # ---- target ----------------------------------------------------------

        # classify, so a plural argument ("Songs") lands on the same class as
        # the singular.
        def target_class_name = @target_class_name ||= target.classify

        def target_singular = @target_singular ||= target_class_name.demodulize.underscore
        def target_plural = @target_plural ||= target_singular.pluralize
        def target_human_singular = target_singular.humanize
        def target_human_plural = target_plural.humanize

        # The has_many name on the owner, and the signal on the form.
        def association_name = target_plural
        def ids_attr = "#{target_singular}_ids"

        def toggle_action = "toggle_#{target_singular}"
        def search_action = "search_#{target_plural}"
        def extras_key = "#{target_plural}_multiselect"

        def target_class
          @target_class ||= begin
            klass = target_class_name.safe_constantize
            raise ::Rails::Generators::Error, missing_target_message unless klass

            klass.tap(&:columns_hash)
          rescue ::Rails::Generators::Error
            raise
          rescue StandardError
            raise ::Rails::Generators::Error,
                  "#{target_class_name} has no table yet. Run bin/rails db:migrate first."
          end
        end

        # ---- join ------------------------------------------------------------

        # The has_many :through reflection on the owner, when the app already
        # declares it — the join argument is redundant there.
        def through_reflection
          return @through_reflection if defined?(@through_reflection)

          reflection = owner_class.reflect_on_association(association_name.to_sym)
          if reflection && !reflection.through_reflection
            raise ::Rails::Generators::Error,
                  "#{class_name}##{association_name} is not a has_many :through — " \
                  "hibiki:rails:multiselect only supports join-model associations."
          end

          @through_reflection = reflection
        end

        def association_declared? = !through_reflection.nil?

        def join_class_name
          @join_class_name ||= if join.present?
                                 join.classify
                               elsif association_declared?
                                 through_reflection.through_reflection.klass.name
                               else
                                 raise ::Rails::Generators::Error,
                                       "#{class_name} has no #{association_name} association — " \
                                       "name the join model:\n    " \
                                       "bin/rails g hibiki:rails:multiselect #{name} #{target} <Join>"
                               end
        end

        def join_singular = join_class_name.demodulize.underscore
        def join_plural = join_singular.pluralize
        def join_table_name = join_class_name.tableize.tr("/", "_")
        def join_model_path = File.join("app/models", "#{join_class_name.underscore}.rb")

        def join_class = @join_class ||= join_class_name.safe_constantize

        # The join is the one model this generator may CREATE: no constant, no
        # file, and no association already routing through something else.
        def join_missing? = join_class.nil? && !exists?(join_model_path)

        # ---- owner -----------------------------------------------------------

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

        # The multiselect rides the scaffold's inline edit form: without the
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
          "No model #{class_name}. hibiki:rails:multiselect extends an existing " \
            "hibiki:rails scaffold — run that first."
        end

        def missing_target_message
          "No model #{target_class_name}. The target model must already exist:\n    " \
            "bin/rails g model #{target_class_name} name:string"
        end

        # ---- the emitted names -------------------------------------------------

        def concern_name = "#{target_plural.camelize}Multiselect"
        def concern_module_name = "#{collection_channel_class_name}::#{concern_name}"

        def concern_path
          File.join("app/channels/concerns", "#{controller_file_path}_channel",
                    "#{target_plural}_multiselect.rb")
        end

        def multiselect_partial = "#{target_plural}_multiselect"
        def component_class_name = view_class_name(:"#{target_plural}_multiselect")

        # ---- the label column --------------------------------------------------

        # The same candidates the scaffold resolves a belongs_to label from,
        # so the two generators guess identically.
        def label_column
          @label_column ||= (options[:label] || inferred_label_column).to_sym
        end

        def inferred_label_column
          strings = target_class.columns.select { it.type == :string }.map(&:name)
          (ModelIntrospection::LABEL_CANDIDATES & strings).first || strings.first ||
            raise(::Rails::Generators::Error,
                  "#{target_class_name} has no string column to label options with — " \
                  "pass one: --label=<column>")
        end

        # ---- template knobs ------------------------------------------------------

        def search? = !options[:skip_search]
        def limit = Integer(options[:limit])

        # What the concern merges under the extras key: with search, the
        # options hash plus the live query (the view re-renders the filter
        # input's value); without, the options hash alone.
        def extras_value_source
          base = "@#{target_plural}_options.value"
          search? ? "#{base}.merge(query: @#{target_plural}_query.value)" : base
        end

        # ---- shared arg builders (both view layers) ------------------------------

        def dom_ref = phlex? ? "@dom" : "dom"

        def option_checkbox_args
          [%("checked"), "id", "#{form_ref}.#{ids_attr}.include?(id)",
           %(id: "\#{#{dom_ref}}_#{target_singular}_\#{id}"),
           *css_args(:checkbox_sm),
           %(**on(:#{toggle_action}, event: :change, with: { id: id, dom: #{dom_ref} }))]
        end

        def filter_field_args
          [%("query"), "ms[:query]",
           %(id: "\#{#{dom_ref}}_#{target_plural}_query"),
           %(placeholder: "Filter #{target_human_plural.downcase}"),
           %(autocomplete: "off"),
           *css_args(:filter_input),
           %(**on(:#{search_action}, event: :input))]
        end
      end
    end
  end
end
