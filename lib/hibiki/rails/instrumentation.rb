# frozen_string_literal: true

module Hibiki
  module Rails
    # The channel's ActiveSupport::Notifications events (`*.hibiki_rails`).
    # Always on: with no subscriber `instrument` only yields. The gem
    # subscribes to none of them. A subscriber runs on the graph thread, so
    # it holds up that graph for as long as it takes.
    #
    # All private — a public helper would become a client-invocable action
    # (see the NOTE on Hibiki::Rails::Channel).
    module Instrumentation
      # The most trips one action may report, and the longest time one may
      # claim, in ms. The figures come from a browser, so they are bounded
      # rather than believed.
      TRIP_LIMIT = 5
      TRIP_RANGE = (0..60_000)

      EVENTS = %w[subscribe unsubscribe action skip render trip].to_h { [it, "#{it}.hibiki_rails"] }.freeze

      private

      # With nobody listening this is one lookup and a yield; no payload is
      # built.
      def instrument(event, payload = nil, &)
        return (yield({}) if block_given?) unless listening?(event)

        ActiveSupport::Notifications.instrument(EVENTS.fetch(event), { channel: self.class.name, **payload }, &)
      end

      # `asked` is the clock as the cable thread posted the action; `wait` is
      # how long the graph thread took to reach it, in ms. An action the
      # channel does not have gets no event: the name is the client's, and a
      # subscriber that stores it must not be handed arbitrary strings.
      def instrument_action(data, asked)
        action = data["action"].to_s
        return yield unless listening?("action") && self.class.action_methods.include?(action)

        before = @__hibiki_render_count.to_i
        instrument("action", { action:, wait: ms_since(asked) }) do |payload|
          yield
        ensure
          payload[:renders] = @__hibiki_render_count.to_i - before
        end
      end

      # A replaceable action a newer one replaced before it ran: no work, so
      # only the wait. Its name was checked against action_methods at
      # subscribe.
      def instrument_skip(data, asked)
        instrument("skip", { action: data["action"], wait: ms_since(asked) }) if listening?("skip")
      end

      def listening?(event) = ActiveSupport::Notifications.notifier.listening?(EVENTS.fetch(event))

      def ms_since(clock) = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - clock) * 1000

      def instrument_render(method:, target: nil, &)
        @__hibiki_render_count = @__hibiki_render_count.to_i + 1
        instrument("render", { target:, method: }.compact, &)
      end

      # The trips a browser reported under `hbt`, as event payloads. Each is
      # `[action, ack, paint]`: ms to the ack, and ms to the first render, or
      # nil when nothing rendered.
      def trips_from(reported)
        reported.is_a?(Array) ? reported.first(TRIP_LIMIT).filter_map { trip(*it) } : []
      end

      def trip(action = nil, ack = nil, paint = nil, *)
        return unless action.is_a?(String) && self.class.action_methods.include?(action)
        return unless ack.is_a?(Numeric) && (paint.nil? || paint.is_a?(Numeric))

        { action:, ack: ack.clamp(TRIP_RANGE), paint: paint&.clamp(TRIP_RANGE) }
      end
    end
  end
end
