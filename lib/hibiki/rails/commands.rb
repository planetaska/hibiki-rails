# frozen_string_literal: true

require "json"

module Hibiki
  module Rails
    # What Helpers#js builds: a list of things the browser does on an event
    # with no round trip, in order. Each method returns a new list, so one
    # can be kept and extended:
    #
    #   js.toggle("#menu")
    #   js.hide("#panel").push(:cancel)
    #   js.add_class("open", to: { closest: "li" })
    #
    # A target is a CSS selector looked up in the whole document,
    # `{ inner: selector }` (inside the control), `{ closest: selector }`
    # (the control's nearest ancestor), or nothing, which is the control
    # itself. The client runs only the names in OPS and keeps the same list
    # (OPS in hibiki-commands.js). Add a command in both places.
    class Commands
      OPS = %w[
        show hide toggle add_class remove_class toggle_class set_attribute remove_attribute
        toggle_attribute focus focus_first dispatch push show_modal close_dialog
      ].freeze

      # An attribute a command may not write: a handler, a style, markup, or
      # the wiring of this gem and Stimulus.
      REFUSED = /\A(on|style\z|srcdoc\z|data-hibiki-|data-controller\z|data-action\z)/i
      ATTRIBUTE = /\A[a-z_:][a-z0-9_:.-]*\z/i
      SCOPES = %i[inner closest].freeze
      # A dispatched event's name; app events are often namespaced by a colon.
      EVENT = /\A[a-z][a-z0-9_.:-]*\z/i

      attr_reader :ops

      def initialize(ops = [])
        @ops = ops.freeze
        freeze
      end

      # Show, hide or flip an element by its `hidden` attribute, which is
      # also what the server renders it with.
      def show(to = nil) = add("show", to:)
      def hide(to = nil) = add("hide", to:)
      def toggle(to = nil) = add("toggle", to:)

      def add_class(names, to: nil) = add("add_class", to:, names: Commands.names(names))
      def remove_class(names, to: nil) = add("remove_class", to:, names: Commands.names(names))
      def toggle_class(names, to: nil) = add("toggle_class", to:, names: Commands.names(names))

      def set_attribute(name, value, to: nil)
        add("set_attribute", to:, name: Commands.attribute(name), value: value.to_s)
      end

      def remove_attribute(name, to: nil) = add("remove_attribute", to:, name: Commands.attribute(name))

      # Present with `value`, or absent.
      def toggle_attribute(name, value = "", to: nil)
        add("toggle_attribute", to:, name: Commands.attribute(name), value: value.to_s)
      end

      def focus(to = nil) = add("focus", to:)

      # The first control inside the target that can take focus.
      def focus_first(to = nil) = add("focus_first", to:)

      # A CustomEvent on the target, for the page's own JavaScript.
      def dispatch(name, to: nil, detail: nil, bubbles: true)
        add("dispatch", to:, name: Commands.event(name), detail:, bubbles: (false unless bubbles))
      end

      # A channel action, as `on(:action, with:)` sends it.
      def push(action, with: nil) = add("push", action: Helpers.event_name(action), with:)

      # A <dialog>, by its own methods: the browser keeps focus inside it,
      # closes it on Escape and gives focus back. With no target,
      # close_dialog closes the one the control is in.
      def show_modal(to) = add("show_modal", to: to || raise(ArgumentError, "show_modal needs a target"))
      def close_dialog(to = nil) = add("close_dialog", to:)

      def push? = ops.any? { it.first == "push" }
      def empty? = ops.empty?
      def to_json(*) = JSON.generate(ops)

      def self.names(names)
        list = Array(names).flat_map { it.to_s.split }
        raise ArgumentError, "a class command needs at least one class name" if list.empty?

        list
      end

      def self.event(name)
        name = name.to_s
        return name if EVENT.match?(name)

        raise ArgumentError, "dispatched event #{name.inspect} must match #{EVENT.inspect}"
      end

      def self.attribute(name)
        name = name.to_s
        return name if ATTRIBUTE.match?(name) && !REFUSED.match?(name)

        raise ArgumentError, "attribute #{name.inspect} is not one a command may write"
      end

      def self.target(to)
        return selector(to) if to.is_a?(String)
        return { to.keys.first.to_s => selector(to.values.first) } if scoped?(to)

        raise ArgumentError,
              "command target #{to.inspect} must be a selector, { inner: selector } or { closest: selector }"
      end

      def self.scoped?(to) = to.is_a?(Hash) && to.size == 1 && SCOPES.include?(to.keys.first)

      def self.selector(value)
        return value if value.is_a?(String) && !value.strip.empty?

        raise ArgumentError, "command selector #{value.inspect} must be a non-empty string"
      end

      private

      def add(name, to: nil, **args)
        args[:to] = Commands.target(to) unless to.nil?
        self.class.new([*ops, [name, args.compact.transform_keys(&:to_s)]])
      end
    end
  end
end
