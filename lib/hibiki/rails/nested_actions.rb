# frozen_string_literal: true

module Hibiki
  module Rails
    # Generic channel actions for reactive_nested forms — include next to
    # Hibiki::Rails::Channel on channels that render nested fieldsets.
    # Opt-in on purpose: every public method here becomes a client-invocable
    # action.
    #
    # A control addresses a node with `path`, alternating association names
    # and child keys, any depth:
    #
    #   "credits"                       # the collection (add targets)
    #   "credits/c3"                    # a child      (remove/set_field)
    #   "credits/c3/contributions/n1"   # a grandchild
    #
    # plus `dom` naming which open form the write aims at ("song_7" vs
    # "song_new"), resolved by #nested_form_for — override it if the channel
    # holds its forms in something other than the scaffold's
    # @form/@editing_id and @new_form/@creating ivars.
    #
    # Every hop is gated: the association against the form class's
    # reactive_nested declarations, the key against live children, a field
    # against the child class's hibiki_attributes. Anything stale or forged
    # drops the action.
    module NestedActions
      def nested_add(data)
        owner, name, child = __hibiki_nested_target(data)
        owner.nested_add(name) if owner && child.nil?
      end

      def nested_remove(data)
        owner, name, child = __hibiki_nested_target(data)
        owner.nested_remove(name, child) if child
      end

      # The changed control's value arrives under its own name, which the
      # views build as "#{path}/#{field}" — per-child unique, and inert in
      # a submit payload (assign only reads declared scalars).
      def nested_set_field(data)
        _owner, _name, child = __hibiki_nested_target(data)
        return unless child

        field = data["field"].to_s.to_sym
        return unless child.class.hibiki_attributes.include?(field)

        key = "#{data['path']}/#{data['field']}"
        child.public_send(:"#{field}=", data[key]) if data.key?(key)
      end

      private

      # Which open form a nested write aims at; nil drops it.
      def nested_form_for(dom)
        if dom.end_with?("_new")
          @new_form if @creating&.peek
        elsif @editing_id&.peek
          @form
        end
      end

      # Walk the path from the top form: [owner, association, child] with
      # child nil for a collection address, or nil when any hop fails.
      def __hibiki_nested_target(data)
        form = nested_form_for(data["dom"].to_s)
        segments = data["path"].to_s.split("/")
        __hibiki_resolve_path(form, segments) if form && !segments.empty?
      end

      def __hibiki_resolve_path(form, segments)
        loop do
          name = segments.shift.to_sym
          return unless form.class.hibiki_nested.key?(name)
          return [form, name, nil] if segments.empty?

          key = segments.shift
          child = form.public_send(name).find { it.nested_key == key }
          return unless child
          return [form, name, child] if segments.empty?

          form = child
        end
      end
    end
  end
end
