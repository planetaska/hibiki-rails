# frozen_string_literal: true

require "concurrent/atomic/atomic_reference"

module Hibiki
  module Rails
    # Skips a replaceable action that the next one replaced (see
    # ClassMethods#replaceable on Hibiki::Rails::Channel). One per
    # subscription. #enter is called as each action is posted, in `hbk` order
    # under ActionOrder's lock, so it needs no lock of its own: "the next
    # action" means the next one the browser sent.
    #
    # Only the action right behind counts. Skipping across others would run
    # them against state the visitor never saw on the page.
    class Replacement
      # An action posted to the graph and not yet run. Started and replaced
      # are both final, and compare_and_set lets only one of them win: the
      # graph thread starting the job, or a cable thread replacing it.
      class Slot
        def initialize = @state = Concurrent::AtomicReference.new(:queued)

        # True when the job may run, false when a newer one replaced it.
        def start = @state.compare_and_set(:queued, :started)

        def replace = @state.compare_and_set(:queued, :replaced)
      end

      # Checked here, at subscribe, rather than by the macro: the methods it
      # names may be defined below it.
      def self.for(channel)
        unknown = channel.replaceable_actions - channel.action_methods.to_a
        raise ArgumentError, "#{channel} declares replaceable #{unknown.join(', ')}, not an action" if unknown.any?

        new
      end

      # A kind of nil (not replaceable, or no number to order it by) gets no
      # slot and replaces nothing, but it still comes between the action
      # before it and the next. An action with no number enters outside the
      # lock (ActionOrder passes it straight through); it only clears, so at
      # worst it fails to come between two it had no order against anyway.
      def enter(kind)
        @slot&.replace if kind && kind == @kind
        @kind = kind
        @slot = (Slot.new if kind)
      end
    end
  end
end
