# frozen_string_literal: true

require "rails/generators/generated_attribute"

module Hibiki
  module Rails
    module Generators
      # One column of a scaffolded resource.
      #
      # Both sources wrap a ::Rails::Generators::GeneratedAttribute, even when
      # the facts came from a real schema, because railties' own per-version
      # knowledge rides on it: #field_type answers :textarea on Rails 8.1 and
      # :text_area on 7.1, which is the difference between a generated _form
      # that runs on this gem's floor and one that doesn't. Synthesizing the
      # attribute on the introspection path buys that for both paths at once.
      class ScaffoldColumn
        # Types that can carry a LIKE term.
        TEXTUAL = %i[string text].freeze

        # Types a sort control can order by. Text is excluded deliberately: an
        # unbounded blob is a meaningless sort key, and §11.6 wants an index
        # per sortable column. Boolean is excluded because two values is a
        # filter, not an order.
        COMPARABLE = %i[string integer decimal float date datetime time].freeze

        # Which *_tag helper renders the control in the channel-backed form.
        # These are the OLD names on purpose: Rails 8.1 renamed them to
        # #textarea_tag / #checkbox_tag but kept these as aliases, while 7.1
        # and 7.2 have only these. One spelling valid across the whole
        # supported matrix beats a version branch in a template.
        TAG_HELPERS = {
          string: :text_field_tag, text: :text_area_tag,
          integer: :number_field_tag, decimal: :text_field_tag,
          float: :text_field_tag, date: :date_field_tag,
          datetime: :datetime_field_tag, time: :time_field_tag,
          boolean: :check_box_tag
        }.freeze

        # Which DOM event a control reports on. Free text and numbers report
        # per keystroke (Helpers#on debounces :input at 250ms) so live
        # validation and dirty? follow the typing; selects, dates and
        # checkboxes have no intermediate states worth reporting.
        KEYSTROKE_TYPES = %i[string text integer decimal float].freeze

        # AR's own comparison vocabulary, mapped to the negation that makes an
        # error message true. Using AR's wording means the message a field
        # shows BEFORE a round trip is the message the record produces after
        # one.
        COMPARISONS = {
          greater_than: "<=", greater_than_or_equal_to: "<",
          less_than: ">=", less_than_or_equal_to: ">"
        }.freeze

        attr_reader :attr, :reflection, :validators

        def initialize(attr:, required: false, reflection: nil,
                       label_column: nil, validators: [])
          @attr = attr
          @required = required
          @reflection = reflection
          @label_column = label_column
          @validators = validators
        end

        def type = attr.type
        def required? = @required
        def human_name = attr.human_name
        def belongs_to? = !reflection.nil? || attr.reference?

        # From the reflection when there is one: `belongs_to :author,
        # foreign_key: :writer_id` is the case where the association's name and
        # its column genuinely disagree, and GeneratedAttribute can only guess.
        def name
          @name ||= (reflection ? reflection.foreign_key : attr.column_name).to_sym
        end

        def association_name = @association_name ||= (reflection&.name || attr.name).to_sym

        def association_class_name
          @association_class_name ||= reflection&.class_name || attr.name.camelize
        end

        # Which column of the ASSOCIATED table a select displays. Only the
        # introspection path can know it; the attribute path has no second
        # schema to look at, so it guesses :name and the generator's
        # post-install output says so out loud. Defaulted here rather than at
        # each call site — a nil leaking into a template emits `order(:)`.
        def label_column = @label_column || :name

        # What the row partial prints. A belongs_to contributes the
        # association's label rather than its id, which is why the model gets a
        # `delegate :name, to: :author, prefix: true` — the record and the row
        # projection then answer the same reader, so one partial serves both.
        def display_reader
          belongs_to? ? :"#{association_name}_#{label_column}" : name
        end

        def options_local = :"#{association_name}_options"
        def form_field_helper = belongs_to? ? :collection_select : attr.field_type
        def tag_field_helper = belongs_to? ? :select_tag : TAG_HELPERS.fetch(type, :text_field_tag)

        def tag_event
          return :change if belongs_to?

          KEYSTROKE_TYPES.include?(type) ? :input : :change
        end

        def searchable? = !belongs_to? && TEXTUAL.include?(type)
        def filterable? = type == :boolean
        def sortable? = !belongs_to? && COMPARABLE.include?(type)
        def numeric? = %i[integer decimal float].include?(type)

        # `min:` / `max:` for a number field, from the same numericality
        # validator that produces the live error. Nothing is invented: a column
        # with no validator gets no bounds.
        def html_bounds
          return {} unless numeric?

          { min: lower_bound, max: upper_bound }.compact
        end

        # The right-hand side of one entry in the form's live_errors derived,
        # or nil when nothing about this column is knowable before a round
        # trip. Clauses are OR-ed so a column can be both required and bounded;
        # with a single clause this is byte-identical to a hand-written entry.
        def live_error_clause
          clauses = [presence_clause, *numericality_clauses, length_clause].compact
          clauses.join(" || ") unless clauses.empty?
        end

        private

        def presence_clause
          return unless required?
          return %{("must be selected" if #{name}.blank?)} if belongs_to?
          return %{("can't be blank" if #{name}.to_s.strip.empty?)} if TEXTUAL.include?(type)

          %{("can't be blank" if #{name}.blank?)}
        end

        def numericality_clauses
          numericality.flat_map do |validator|
            validator.options.filter_map do |option, limit|
              comparison = COMPARISONS[option]
              next unless comparison && limit.is_a?(Numeric)

              message = "must be #{option.to_s.tr('_', ' ')} #{limit}"
              %{("#{message}" if #{name}.#{cast} #{comparison} #{limit})}
            end
          end
        end

        def length_clause
          maximum = validators.find { it.kind == :length }&.options&.fetch(:maximum, nil)
          return unless maximum

          message = "is too long (maximum is #{maximum} characters)"
          %{("#{message}" if #{name}.to_s.length > #{maximum})}
        end

        def cast = type == :integer ? "to_i" : "to_f"
        def numericality = validators.select { it.kind == :numericality }

        def lower_bound
          bound(:greater_than_or_equal_to) || bound(:greater_than)&.succ
        end

        def upper_bound
          bound(:less_than_or_equal_to) || bound(:less_than)&.pred
        end

        def bound(option)
          value = numericality.filter_map { it.options[option] }.first
          value if value.is_a?(Numeric)
        end
      end

      # Reads a live ActiveRecord model into ScaffoldColumns.
      #
      # Its own class because introspection is the path with real steps —
      # ignoring the framework's own columns, pairing foreign keys back to
      # their reflections, resolving a label column through the association,
      # and reading validators. The attribute path is a one-line map by
      # comparison, which is why only this half is worth naming.
      class ModelIntrospection
        # What a belongs_to's label column is likely to be called, in
        # preference order. Only reachable on this path: no argument list can
        # state what column of another table a select should display.
        LABEL_CANDIDATES = %w[name title label email].freeze

        def initialize(model)
          @model = model
          belongs_tos = model.reflect_on_all_associations(:belongs_to)
          @polymorphic = belongs_tos.select(&:polymorphic?)
          @by_foreign_key = (belongs_tos - @polymorphic).index_by { it.foreign_key.to_s }
        end

        def columns
          @model.columns_hash.each_value.filter_map do |column|
            next if ignored.include?(column.name)

            reflection = @by_foreign_key[column.name]
            reflection ? reference_column(reflection) : scalar_column(column)
          end
        end

        def skipped
          @polymorphic.map { [it.name.to_s, ScaffoldSchema::REFUSALS[:polymorphic?]] }
        end

        def timestamps? = @model.columns_hash.key?("created_at")

        private

        # The primary key, the timestamps, STI's discriminator and the
        # optimistic-locking counter are all framework bookkeeping — excluded
        # silently, unlike REFUSALS, because nobody asked for them.
        def ignored
          @ignored ||= [@model.primary_key, *ScaffoldSchema::TIMESTAMPS,
                        @model.inheritance_column, "lock_version",
                        *@polymorphic.flat_map { [it.foreign_key.to_s, it.foreign_type.to_s] }].compact
        end

        def reference_column(reflection)
          ScaffoldColumn.new(
            attr: ::Rails::Generators::GeneratedAttribute.new(reflection.name.to_s, :references),
            required: belongs_to_required?(reflection),
            reflection: reflection,
            label_column: label_column_for(reflection),
            validators: @model.validators_on(reflection.foreign_key)
          )
        end

        def scalar_column(column)
          validators = @model.validators_on(column.name)

          ScaffoldColumn.new(
            attr: ::Rails::Generators::GeneratedAttribute.new(column.name, column.type),
            required: required_scalar?(column, validators),
            validators: validators
          )
        end

        def belongs_to_required?(reflection)
          return !reflection.options[:optional] if reflection.options.key?(:optional)
          return false unless @model.respond_to?(:belongs_to_required_by_default)

          !!@model.belongs_to_required_by_default
        end

        # A `null: false` column WITH a default can never be violated through a
        # form — a blank submit takes the default — so it is not "required" for
        # the purposes of a message shown before any round trip. A boolean is
        # never blank either. This is why a column that genuinely has a floor
        # needs a real numericality validator rather than its null constraint.
        def required_scalar?(column, validators)
          return true if validators.any? { it.kind == :presence }

          !column.null && column.default.nil? && column.type != :boolean
        end

        def label_column_for(reflection)
          klass = reflection.klass
          strings = klass.columns_hash.select { |_, column| column.type == :string }.keys
          ((LABEL_CANDIDATES & strings).first || strings.first || klass.primary_key).to_sym
        rescue StandardError
          # An unresolvable class_name must not take the whole generator down
          # over a label; the post-install output states the guess either way.
          :name
        end
      end

      # The column list a scaffold generator hands its templates, plus every
      # list derived from it.
      #
      # Two builders, because a scaffold has two genuinely different sources of
      # truth and neither covers both commands:
      #
      #   from_attributes  `hibiki:rails:scaffold Book title:string` — the
      #                    migration has NOT run when the controller generator
      #                    is invoked, so the schema does not exist yet.
      #   from_model       `hibiki:rails:scaffold_controller Book` with no
      #                    field list — the only source is the real schema.
      #
      # Explicit attributes always win, matching Rails' own precedence.
      class ScaffoldSchema
        TIMESTAMPS = %w[created_at updated_at].freeze

        # Attribute shapes that cannot be a ReactiveForm signal, a Data member
        # or a collection_select. They are refused out loud rather than emitted
        # half-working: a silently dropped column is the §10 failure class,
        # where everything looks generated and one field is quietly missing.
        REFUSALS = {
          rich_text?: "rich text needs its own editor and cannot be a form signal",
          attachment?: "Active Storage attachments are not form signals",
          attachments?: "Active Storage attachments are not form signals",
          password_digest?: "a password digest must not travel over a channel",
          token?: "a token must not travel over a channel",
          polymorphic?: "a polymorphic belongs_to has no single collection to select from"
        }.freeze

        attr_reader :columns, :skipped

        class << self
          def refusal_for(attr) = REFUSALS.find { |query, _| attr.public_send(query) }&.last

          def from_attributes(attributes, timestamps: true)
            supported, refused = attributes.partition { refusal_for(it).nil? }

            new(columns: supported.map { column_from_attribute(it) },
                skipped: refused.map { |attr| [attr.name, refusal_for(attr)] },
                timestamps: timestamps, introspected: false)
          end

          def from_model(model)
            introspection = ModelIntrospection.new(model)

            new(columns: introspection.columns, skipped: introspection.skipped,
                timestamps: introspection.timestamps?, introspected: true)
          end

          private

          def column_from_attribute(attr)
            ScaffoldColumn.new(
              attr: attr,
              # GeneratedAttribute#required? is belongs_to-only — a scalar
              # `title:string!` records null: false in attr_options and leaves
              # #required? false. Both halves matter here.
              required: attr.required? || attr.attr_options[:null] == false
            )
          end
        end

        def initialize(columns:, skipped: [], timestamps: true, introspected: false)
          @columns = columns
          @skipped = skipped
          @timestamps = timestamps
          @introspected = introspected
        end

        def introspected? = @introspected
        def timestamps? = @timestamps
        def empty? = columns.empty?

        def searchable = columns.select(&:searchable?).map(&:name)
        def filterable = columns.select(&:filterable?).map(&:name)
        def belongs_tos = columns.select(&:belongs_to?)
        def booleans = columns.select(&:filterable?)
        def attribute_names = columns.map(&:name)
        def searchable? = searchable.any?

        # :id first because it is the default sort and always exists;
        # :created_at last because "newest" is the sort a reader reaches for
        # that no declared column provides. :updated_at is deliberately absent
        # — it moves on every write, so ordering by it makes the list reshuffle
        # under the reader.
        def sortable
          [:id, *columns.select(&:sortable?).map(&:name), *(:created_at if timestamps?)]
        end

        # One grouped COUNT covers both numbers, so the counts sentence gets a
        # boolean breakdown for free. With no boolean column there is nothing
        # to group by and the sentence loses its trailing clause.
        def primary_boolean = booleans.first

        # A belongs_to contributes two members: the foreign key the form binds
        # to, and the label the row partial prints.
        def row_members
          [:id, *columns.flat_map { it.belongs_to? ? [it.name, it.display_reader] : [it.name] }]
        end

        def live_errors
          columns.filter_map { |column| [column.name, column.live_error_clause] if column.live_error_clause }
        end
      end
    end
  end
end
