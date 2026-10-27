# frozen_string_literal: true

require "json"

module Hibiki
  module Rails
    # Helpers#on's per-control modifiers, kept out of the token grammar.
    module Modifiers
      # The attributes beside hibiki_on. Each is omitted when it matches the
      # client's own default, so the common call still stamps exactly one.
      def self.attributes(with:, debounce:, confirm:, reset:, fallback:, replaceable:)
        {
          hibiki_with: (JSON.generate(with) unless with.nil?),
          # nonzero? returns the integer itself, so 0 compacts away.
          hibiki_debounce: (Integer(debounce).nonzero? if debounce),
          hibiki_confirm: confirm&.to_s,
          hibiki_reset: ("false" if reset == false),
          hibiki_fallback: ("true" if fallback),
          hibiki_replaceable: ("true" if replaceable)
        }.compact
      end

      # What stands in for the action name in a token whose control runs a
      # command list. No action can be named this.
      CHAIN = "*"

      # The attribute a command list adds, or nothing for an action name.
      def self.chain(action, with:, fallback:, replaceable:)
        return {} unless action.is_a?(Commands)
        raise ArgumentError, "on(js) needs at least one command" if action.empty?
        raise ArgumentError, "with: belongs on the command: js.push(:action, with: ...)" unless with.nil?
        raise ArgumentError, "replaceable: belongs on an action, not on commands" if replaceable
        raise ArgumentError, "fallback: needs a push in the commands" if fallback && !action.push?

        { hibiki_do: action.to_json }
      end

      # Back is not a gesture on a control: it has nothing to wait for and
      # no native destination to fall back to.
      def self.popstate!(**modifiers)
        given = modifiers.compact.keys
        raise ArgumentError, "a popstate event takes no #{given.join(' or ')}" if given.any?
      end
    end
  end
end
