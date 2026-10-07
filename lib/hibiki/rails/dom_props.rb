# frozen_string_literal: true

module Hibiki
  module Rails
    # The DOM properties Helpers#props may set, and their wire form. The
    # client keeps the same list (PROPS in hibiki.js) and ignores anything
    # outside it, so a fragment can never reach innerHTML or an event
    # handler. Add a property in both places.
    module DomProps
      # Ruby key => [wire name, type].
      ALLOWED = {
        indeterminate: ["indeterminate", :boolean],
        scroll_top: ["scrollTop", :number],
        scroll_left: ["scrollLeft", :number]
      }.freeze

      # One name/value as its wire pair, or nil when there is nothing to
      # send. A boolean is always sent, false included: a morph keeps the
      # element, so an omitted false would leave the property set.
      def self.pair(name, value)
        wire, type = ALLOWED.fetch(name.to_sym) do
          raise ArgumentError,
                "DOM property #{name.inspect} must be one of #{ALLOWED.keys.join(', ')}"
        end
        return [wire, value ? true : false] if type == :boolean
        return if value.nil?
        return [wire, value] if value.is_a?(Numeric) && value.to_f.finite?

        raise ArgumentError, "DOM property #{name} must be a finite number, got #{value.inspect}"
      end
    end
  end
end
