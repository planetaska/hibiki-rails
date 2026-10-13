# frozen_string_literal: true

require "json"

module Hibiki
  module Rails
    # Helpers#on's per-control modifiers, kept out of the token grammar.
    module Modifiers
      # The attributes beside hibiki_on. Each is omitted when it matches the
      # client's own default, so the common call still stamps exactly one.
      def self.attributes(with:, debounce:, confirm:, reset:, fallback:)
        {
          hibiki_with: (JSON.generate(with) unless with.nil?),
          # nonzero? returns the integer itself, so 0 compacts away.
          hibiki_debounce: (Integer(debounce).nonzero? if debounce),
          hibiki_confirm: confirm&.to_s,
          hibiki_reset: ("false" if reset == false),
          hibiki_fallback: ("true" if fallback)
        }.compact
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
