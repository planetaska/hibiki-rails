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
    #     reactive_nested :steps, "StepForm"  # an array-of-child-forms signal
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

        # reactive_nested :steps, "StepForm" — a signal holding an array of
        # child forms over an accepts_nested_attributes_for association.
        # #to_h serializes it as steps_attributes, so #commit persists the
        # whole tree in the record's own save. The child form class may
        # itself declare reactive_nested — depth is composition, nothing
        # here counts levels. Deliberately NOT in hibiki_attributes: that
        # stays the scalar allowlist for set_field/assign-style code.
        def reactive_nested(name, form_class)
          name = name.to_sym
          @hibiki_nested = { **hibiki_nested, name => form_class }
          state(name) { [] }
        end

        def hibiki_attributes
          @hibiki_attributes || __hibiki_inherited(:hibiki_attributes) || []
        end

        def hibiki_model
          model = @hibiki_model || __hibiki_inherited(:hibiki_model)
          raise "#{self} has no reactive_attributes declaration" if model.nil?

          model.is_a?(Module) ? model : model.to_s.constantize
        end

        def hibiki_nested
          @hibiki_nested || __hibiki_inherited(:hibiki_nested) || {}
        end

        # The child form class, resolved on every use like hibiki_model so
        # a String declaration never pins a constant across a reload.
        def hibiki_nested_form(name)
          form = hibiki_nested.fetch(name)
          form.is_a?(Module) ? form : form.to_s.constantize
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
      # Children are rebuilt before the snapshot, so dirty? sees the whole
      # tree as clean.
      def hydrate(record)
        @record = record
        Hibiki.batch do
          __hibiki_hydrate_nested(record)
          self.class.hibiki_attributes.each { |name| public_send(:"#{name}=", record.public_send(name)) }
          __hibiki_destroy.value = false
          __hibiki_snapshot.value = to_h
          __hibiki_errors.value = {}
        end
        self
      end

      def persisted? = record&.persisted? || false

      # Reads every attribute signal (child forms' included), so anything
      # derived from it tracks them all.
      def to_h
        h = self.class.hibiki_attributes.to_h { |name| [name, public_send(name)] }
        self.class.hibiki_nested.each_key do |name|
          h[:"#{name}_attributes"] = public_send(name).map(&:to_nested_attributes)
        end
        h
      end

      # This form's slice of a parent's *_attributes: the id ties the hash
      # to its row (new children have none), _destroy rides along for
      # allow_destroy, and #to_h recursion carries any grandchildren.
      def to_nested_attributes
        attrs = to_h
        attrs[:id] = record.id if persisted?
        attrs[:_destroy] = marked_for_destruction?
        attrs
      end

      # Stable identity for a child form across repaints: "c<id>" for
      # persisted rows, "n<seq>" for added ones. Assigned by the parent —
      # a standalone form has none.
      attr_reader :nested_key

      # Append a fresh child form (hydrated from the child model's column
      # defaults) and return it. The array is replaced, never mutated —
      # signals notify on assignment.
      def nested_add(name)
        form_class = self.class.hibiki_nested_form(name)
        child = form_class.from(form_class.hibiki_model.new)
        child.nested_key = "n#{@__hibiki_key_seq = (@__hibiki_key_seq || 0) + 1}"
        public_send(:"#{name}=", [*public_send(name), child])
        child
      end

      # A persisted child is kept and marked (_destroy does the work at
      # commit); a new one simply leaves the array.
      def nested_remove(name, child)
        if child.persisted?
          child.mark_for_destruction
        else
          public_send(:"#{name}=", public_send(name) - [child])
        end
        child
      end

      # Move a child to index `to` among its VISIBLE siblings — the index
      # the rendered rows show, so marked rows can't shift the target.
      # They ride along at the tail; their order never matters (position
      # stamping and rendering both skip them). Clamped, so any integer is
      # safe.
      def nested_move(name, child, to:)
        children = public_send(name)
        return child if child.marked_for_destruction? || !children.include?(child)

        visible = children.reject(&:marked_for_destruction?)
        visible.delete(child)
        visible.insert(to.clamp(0, visible.size), child)
        public_send(:"#{name}=", visible + (children - visible))
        child
      end

      # AR's spelling; #hydrate is the unmark.
      def mark_for_destruction
        __hibiki_destroy.value = true
      end

      def marked_for_destruction? = __hibiki_destroy.value

      # Write the record. Returns false and mirrors the model's errors into
      # #errors when validation fails (the Rails #save convention). On
      # success the form re-hydrates: callbacks and database defaults may
      # have moved values, and #persisted? flips after an INSERT.
      # rubocop:disable Naming/PredicateMethod -- boolean without a ?, exactly like AR's #save
      def commit
        record = __hibiki_record!
        if record.update(**to_h)
          # Unload before re-hydrating, so the reload honors the
          # association's own scope and drops destroyed rows.
          __hibiki_reset_nested(record)
          hydrate(record)
          true
        else
          __hibiki_mirror_errors(record)
          # The form holds ONE record across attempts, and every failed
          # update APPENDS its built new children to the in-memory
          # association — a later success would insert them all again.
          # Unloading makes the next attempt start clean.
          __hibiki_reset_nested(record)
          false
        end
      end
      # rubocop:enable Naming/PredicateMethod

      # The raising half. Re-assigns and raises ActiveRecord::RecordInvalid
      # (no rescue, and no AR constant named here); the nested associations
      # are unloaded even on the raise, so a rescued retry starts clean.
      def commit!
        return true if commit

        record = __hibiki_record!
        begin
          record.update!(**to_h)
        ensure
          __hibiki_reset_nested(record)
        end
      end

      # { title: ["can't be blank"] } — mirrored at a failed commit,
      # cleared at a successful one. Reactive like any other signal read:
      # an effect over #error_for repaints when a commit fails.
      def errors = __hibiki_errors.value

      def error_for(name) = errors[name.to_sym]&.first

      protected

      # The parent assigns keys while building children; standalone code
      # has no business writing one.
      attr_writer :nested_key

      # Distribute a failed save's messages by walking the child RECORD
      # OBJECTS rather than parsing indexed error keys: the nested
      # assignment mutated the loaded persisted children in place (matched
      # by id), and its builds appear among the unsaved targets in the same
      # order as our new children. New children marked _destroy are never
      # built at all, so they are skipped to keep that order aligned.
      def __hibiki_mirror_errors(record)
        __hibiki_errors.value = record.errors.to_hash
        self.class.hibiki_nested.each_key do |name|
          __hibiki_mirror_child_errors(public_send(name), record.public_send(name).to_a)
        end
      end

      private

      # Snapshot and errors are plain States rather than `state` macros on
      # purpose: the macro would generate public writers and invite writes
      # that bypass #hydrate and #commit.
      def __hibiki_snapshot = @__hibiki_snapshot ||= Hibiki::State.new({})

      def __hibiki_errors = @__hibiki_errors ||= Hibiki::State.new({})

      def __hibiki_destroy = @__hibiki_destroy ||= Hibiki::State.new(false)

      def __hibiki_mirror_child_errors(children, targets)
        new_targets = targets.reject(&:persisted?)
        children.each do |child|
          # A new child marked _destroy was never built — skipping it keeps
          # the positional walk aligned.
          next if !child.persisted? && child.marked_for_destruction?

          target = child.persisted? ? targets.find { it.id == child.record.id } : new_targets.shift
          child.__hibiki_mirror_errors(target) if target
        end
      end

      def __hibiki_hydrate_nested(record)
        self.class.hibiki_nested.each_key do |name|
          public_send(:"#{name}=", record.public_send(name).map { __hibiki_build_child(name, it) })
        end
      end

      def __hibiki_build_child(name, child_record)
        child = self.class.hibiki_nested_form(name).from(child_record)
        child.nested_key =
          child_record.persisted? ? "c#{child_record.id}" : "n#{@__hibiki_key_seq = (@__hibiki_key_seq || 0) + 1}"
        child
      end

      # #reset on a collection unloads it without a query; the next read
      # reloads through the association's own scope.
      def __hibiki_reset_nested(record)
        self.class.hibiki_nested.each_key { |name| record.public_send(name).reset }
      end

      def __hibiki_record!
        record || raise("#{self.class} has no record — build it with .from(record)")
      end
    end
  end
end
