# frozen_string_literal: true

module Hibiki
  module Rails
    # The key events Helpers#on may name, and their wire form:
    # `keydown.[<modifier>+]*<key>[@window]`. The client keeps the same key
    # list (KEYS in hibiki.js) and matches nothing outside it. Add a key in
    # both places.
    module Keys
      # Named keys, Stimulus's spellings. Single letters and digits are
      # keys too.
      NAMES = %w[enter tab esc space up down left right home end page_up page_down].freeze
      CHARACTER = /\A[a-z0-9]\z/

      # In wire order. No alt: on macOS Option changes the character the
      # key reports, so `alt+s` would never match there.
      MODIFIERS = %w[ctrl meta shift].freeze

      SCOPES = %w[window].freeze

      # What Helpers#on hands over: `keydown` alone or followed by a
      # qualifier, not a longer name that starts with it.
      EVENT = /\Akeydown(?![a-z0-9_-])/i

      # One `keydown...` event as its canonical token: lowercase, modifiers
      # in MODIFIERS order.
      def self.token(event)
        event = event.to_s.downcase
        unless EVENT.match?(event)
          raise ArgumentError, "event #{event.inspect}: only a keydown.<key> event takes a scope"
        end

        combo, scope = event.split("@", 2)
        *modifiers, key = combo.delete_prefix("keydown").delete_prefix(".").split("+")
        key!(event, key)
        modifiers!(event, key, modifiers)
        scope!(event, scope)
        ["keydown.#{[*(MODIFIERS & modifiers), key].join('+')}", scope].compact.join("@")
      end

      def self.key!(event, key)
        if key.nil?
          raise ArgumentError,
                "#{event.inspect} names no key; write keydown.<key>, or use :input for typed text"
        end
        return if NAMES.include?(key) || CHARACTER.match?(key)

        raise ArgumentError,
              "key #{key.inspect} in #{event.inspect} must be a letter, a digit, or one of #{NAMES.join(', ')}"
      end

      def self.modifiers!(event, key, modifiers)
        unknown = modifiers - MODIFIERS
        unless unknown.empty?
          raise ArgumentError,
                "modifier #{unknown.first.inspect} in #{event.inspect} must be one of #{MODIFIERS.join(', ')}"
        end
        return unless modifiers.include?("shift") && key.match?(/\A\d\z/)

        # Shift turns a digit into punctuation, so the key would never match.
        raise ArgumentError, "#{event.inspect}: shift cannot be combined with a digit"
      end

      def self.scope!(event, scope)
        return if scope.nil? || SCOPES.include?(scope)

        raise ArgumentError, "scope #{scope.inspect} in #{event.inspect} must be #{SCOPES.join(', ')}"
      end

      private_class_method :key!, :modifiers!, :scope!
    end
  end
end
