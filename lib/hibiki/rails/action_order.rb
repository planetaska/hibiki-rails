# frozen_string_literal: true

require "concurrent/scheduled_task"

module Hibiki
  module Rails
    # Puts one subscription's incoming actions back in the order the client
    # sent them. ActionCable hands every websocket message to a worker pool
    # (Connection#receive is send_async), so two actions sent back to back
    # can reach Channel#perform_action in either order — and the client's
    # flush sends a typed field and the click after it in one tick.
    #
    # The client numbers its actions under `hbk`, from 1 per subscription
    # with no gaps. #submit calls each job when its number comes up: one
    # ahead of its turn is held until the missing ones arrive, or until
    # GRACE runs out for that gap (a client older than this numbers on
    # across a reconnect, so its first action there waits one grace). A
    # number whose turn has passed, a repeat, and anything that is not an
    # Integer run at once.
    #
    # Jobs run under the lock, on whichever thread releases them, so they
    # must only enqueue: the order of the calls is the order of the queue.
    # Like Registry, this is glue touched from many cable threads, not the
    # graph; a lock is the right tool here.
    class ActionOrder
      # Seconds one gap is waited for. A websocket does not lose messages,
      # so only a number that was never sent waits it out.
      GRACE = 0.1

      def initialize
        @lock = Mutex.new
        @due = 1
        @held = {}
        @closed = false
      end

      def submit(seq, &job)
        return job.call unless seq.is_a?(Integer)

        @lock.synchronize do
          next job.call if @closed || seq < @due || @held.key?(seq)

          @held[seq] = job
          release
        end
      end

      # Run what is held, in order, and let everything after straight
      # through. Channel#unsubscribed calls it ahead of the dispose.
      def close
        @lock.synchronize do
          @closed = true
          disarm
          @held.sort.each { |_, job| job.call }
          @held.clear
        end
      end

      private

      def release
        while (job = @held.delete(@due))
          @due += 1
          job.call
        end
        watch
      end

      # One timer per gap: more arrivals behind the same gap do not restart
      # it. `@waiting` is the number waited for, which is also what tells a
      # timer that fires late it is stale.
      def watch
        return disarm if @held.empty?
        return if @waiting == @due

        disarm
        waiting = @waiting = @due
        @timer = Concurrent::ScheduledTask.execute(GRACE) { give_up(waiting) }
      end

      def disarm
        @timer&.cancel
        @timer = @waiting = nil
      end

      def give_up(waiting)
        @lock.synchronize do
          next unless @waiting == waiting

          @due = @held.keys.min
          release
        end
      end
    end
  end
end
