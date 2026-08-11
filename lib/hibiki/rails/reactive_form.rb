# frozen_string_literal: true

module Hibiki
  module Rails
    # A reactive form object over one ActiveRecord record: hydrate its
    # attributes into signals at one edge, work reactively in the middle,
    # commit back at the other. The record itself never enters the graph.
    #
    #   class TodoForm
    #     include Hibiki::Rails::ReactiveForm
    #
    #     reactive_attributes Todo, :title, :done
    #     reactive_association :tags          # defines the tag_ids signal
    #
    #     derived(:title_error) { "can't be blank" if title.strip.empty? }
    #     derived(:valid?)      { title_error.nil? }
    #   end
    #
    #   form = TodoForm.from(Todo.find(id))   # or Todo.new — see below
    #   form.title = "buy milk"               # a plain signal write
    #   form.dirty?                           # => true
    #   form.commit                           # => false if invalid
    #   form.error_for(:title)                # => the model's own message
    #
    # One form class serves create AND update, the `form_with model:`
    # convention: `from(Todo.new)` hydrates the column defaults and `commit`
    # on an unpersisted record INSERTs, so create-vs-update is invisible to
    # the caller. `dirty?` on a create form means "changed from the
    # defaults" — exactly what enables a Create button.
    #
    # Two layers of validation, deliberately: hand-written deriveds give
    # per-keystroke feedback (hand-picked, like client-side validation),
    # while the model's own `validates` stay authoritative at commit and
    # land in #errors. Nothing here names an ActiveRecord constant — the
    # record is duck-typed (readers, #update, #save!, #errors,
    # #persisted?) — but the casting below is AR's attribute API, which is
    # why this lives in the Rails glue gem and not in the core.
    module ReactiveForm
      def self.included(base)
        base.include(Hibiki::Reactive)
        base.extend(ClassMethods)
        # One derived over the whole attribute set rather than per-field
        # change tracking: cheap, and enough for "enable the save button".
        base.derived(:dirty?) { to_h != __hibiki_snapshot.value }
      end

      module ClassMethods
        # Hydrate from a record — the only supported constructor. Extra
        # arguments are forwarded to #initialize, so a form with its own
        # constructor still works.
        def from(record, ...) = new(...).hydrate(record)

        # reactive_attributes Todo, :title, :done
        #
        # The model may be a Class or a String/Symbol; a name is resolved on
        # every use, so a form class under app/ never pins a constant across
        # a Zeitwerk reload.
        def reactive_attributes(model, *names)
          @hibiki_model = model
          @hibiki_attributes = names.map(&:to_sym)
          casts = __hibiki_casts
          @hibiki_attributes.each do |name|
            state name
            casts.define_method(:"#{name}=") { |value| super(self.class.hibiki_type(name).cast(value)) }
          end
        end

        # reactive_association :tags — an ids signal (tag_ids) over a
        # collection association, declared AFTER reactive_attributes (the
        # target comes off the model's reflection). Hydrate reads the
        # model's own collection-ids reader and commit hands the ids to
        # #update, where AR's association writer does the join-row
        # bookkeeping — so the macro only owns the signal and its cast:
        # each id goes through the TARGET model's primary-key type, and
        # the multi-select hidden-input blank is dropped.
        def reactive_association(*names)
          raise "#{self}: declare reactive_attributes before reactive_association" unless __hibiki_model_declared?

          names.each { |name| __hibiki_ids_signal(name) }
        end

        def hibiki_attributes
          @hibiki_attributes || __hibiki_inherited(:hibiki_attributes) || []
        end

        def hibiki_model
          model = @hibiki_model || __hibiki_inherited(:hibiki_model)
          raise "#{self} has no reactive_attributes declaration" if model.nil?

          model.is_a?(Module) ? model : model.to_s.constantize
        end

        # Channel action params arrive as strings; casting through the
        # model's own attribute type is the difference between
        # `done = "false"` meaning false and meaning true.
        def hibiki_type(name) = hibiki_model.type_for_attribute(name.to_s)

        # The ids cast for a reactive_association: the target model's
        # primary-key type, resolved on every use like hibiki_model so a
        # reload can't pin a stale class.
        def hibiki_association_type(name)
          reflection = hibiki_model.reflect_on_association(name)
          raise "#{hibiki_model} has no #{name} association" if reflection.nil?

          reflection.klass.type_for_attribute(reflection.klass.primary_key)
        end

        private

        # Presence only — deliberately not resolving hibiki_model, which
        # would constantize a String declaration at class-definition time.
        def __hibiki_model_declared?
          !!(@hibiki_model ||
             (superclass.respond_to?(:hibiki_attributes) && superclass.send(:__hibiki_model_declared?)))
        end

        def __hibiki_ids_signal(name)
          attr_name = :"#{name.to_s.singularize}_ids"
          @hibiki_attributes = [*hibiki_attributes, attr_name]
          state attr_name
          __hibiki_casts.define_method(:"#{attr_name}=") do |value|
            type = self.class.hibiki_association_type(name)
            super(Array(value).compact_blank.map { type.cast(it) })
          end
        end

        # Declarations live in class ivars, so subclasses have to walk up
        # for them — the generated methods inherit on their own.
        def __hibiki_inherited(reader)
          superclass.public_send(reader) if superclass.respond_to?(reader)
        end

        # One module per class, prepended once: the casting writer wraps
        # the writer `state` defined on the class itself (via super)
        # instead of replacing it.
        def __hibiki_casts = @__hibiki_casts ||= Module.new.tap { prepend(it) }
      end

      # The record, held in a plain ivar and NEVER in a signal: it is the
      # boundary, touched only by #hydrate and #commit.
      attr_reader :record

      # Also the "reset from a reloaded record" path. One batch, so a
      # re-hydrate is one effect run rather than one per attribute.
      def hydrate(record)
        @record = record
        Hibiki.batch do
          self.class.hibiki_attributes.each { |name| public_send(:"#{name}=", record.public_send(name)) }
          __hibiki_snapshot.value = to_h
          __hibiki_errors.value = {}
        end
        self
      end

      def persisted? = record&.persisted? || false

      # Reads every attribute signal, so anything derived from it tracks
      # them all.
      def to_h = self.class.hibiki_attributes.to_h { |name| [name, public_send(name)] }

      # Write the record. Returns false and mirrors the model's errors into
      # #errors when validation fails (the Rails #save convention). On
      # success the form re-hydrates: callbacks and database defaults may
      # have moved values, and #persisted? flips after an INSERT.
      # rubocop:disable Naming/PredicateMethod -- boolean without a ?, exactly like AR's #save
      def commit
        record = __hibiki_record!
        if record.update(**to_h)
          hydrate(record)
          true
        else
          __hibiki_errors.value = record.errors.to_hash
          false
        end
      end
      # rubocop:enable Naming/PredicateMethod

      # The raising half. #commit has already assigned the attributes and
      # mirrored the errors, so #save! re-validates the same record and
      # raises ActiveRecord::RecordInvalid — no rescue, and no AR constant
      # named here.
      def commit! = commit || __hibiki_record!.save!

      # { title: ["can't be blank"] } — mirrored at a failed commit,
      # cleared at a successful one. Reactive like any other signal read:
      # an effect over #error_for repaints when a commit fails.
      def errors = __hibiki_errors.value

      def error_for(name) = errors[name.to_sym]&.first

      private

      # Snapshot and errors are plain States rather than `state` macros on
      # purpose: the macro would generate public writers and invite writes
      # that bypass #hydrate and #commit.
      def __hibiki_snapshot = @__hibiki_snapshot ||= Hibiki::State.new({})

      def __hibiki_errors = @__hibiki_errors ||= Hibiki::State.new({})

      def __hibiki_record!
        record || raise("#{self.class} has no record — build it with .from(record)")
      end
    end
  end
end
