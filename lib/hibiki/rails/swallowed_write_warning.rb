# frozen_string_literal: true

module Hibiki
  module Rails
    # Dev-only tripwire, prepended onto Hibiki::State by the Engine in
    # development. ActiveRecord's #== is class + id, so re-assigning a
    # reloaded record whose ATTRIBUTES moved is silently dropped by the
    # default write gate — the classic stale-UI debugging session. This
    # warns when that happens; it changes nothing else.
    #
    # A prepend sees State's own @equals/@value. Only the default gate
    # (@equals nil → ==) is second-guessed: a custom comparator or
    # `equals: false` changed the gate on purpose. The ivar coupling to
    # core is pinned by spec/swallowed_write_warning_spec.rb.
    module SwallowedWriteWarning
      def value=(new_value)
        if @equals.nil? && new_value == @value &&
           SwallowedWriteWarning.attributes_differ?(@value, new_value)
          ::Rails.logger&.warn(
            "[hibiki_rails] State write dropped by == although attributes " \
            "differ — ActiveRecord id-equality swallowed a real change. " \
            "See \"Working with ActiveRecord\" in the hibiki docs, or pass " \
            "equals: Hibiki::Rails.record_equals."
          )
        end
        super
      end

      # Duck-typed on purpose: nothing in lib/ names an ActiveRecord constant.
      # No size check in the Array branch — the write gate's == already held,
      # so the arrays zip cleanly.
      def self.attributes_differ?(old_value, new_value)
        if old_value.respond_to?(:attributes) && new_value.respond_to?(:attributes)
          old_value.attributes != new_value.attributes
        elsif old_value.is_a?(Array) && new_value.is_a?(Array)
          old_value.zip(new_value).any? { attributes_differ?(it[0], it[1]) }
        else
          false
        end
      end
    end
  end
end
