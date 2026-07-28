# frozen_string_literal: true

module Hibiki
  module Rails
    # Include into an ActionCable channel to host one connection-scoped
    # signal graph:
    #
    #   class CounterChannel < ApplicationCable::Channel
    #     include Hibiki::Rails::Channel
    #
    #     def build_graph                # runs on the graph's own thread,
    #       @count = Hibiki::State.new(0) # inside Hibiki.root
    #       Hibiki::Effect.new { ... broadcast ... }
    #     end
    #
    #     def increment = @count.value += 1  # actions are plain methods
    #   end
    #
    # Lifecycle: `subscribed` rejects without a `cid` param, then builds the
    # graph via #build_graph inside Hibiki.root on a dedicated GraphActor
    # thread; every incoming action runs on that same thread inside one
    # Hibiki.batch (N writes per action still mean one re-run per affected
    # effect); `unsubscribed` disposes the root and stops the actor.
    #
    # A channel that overrides `subscribed`/`unsubscribed` itself must call
    # `super`.
    #
    # NOTE: everything this module adds is private (except the
    # #perform_action override, which ActionCable already exposes) — any
    # other public method would be picked up by Channel#action_methods and
    # become client-invocable.
    module Channel
      def self.included(base)
        base.extend(ClassMethods)
        base.include(Broadcasts)
      end

      module ClassMethods
        private

        # Lifecycle hooks, not client-invocable actions: keep them out of
        # action_methods even when an app defines them public (a client
        # performing "build_graph" would rebuild the graph and leak the old
        # root; "subscribed" would build a SECOND graph actor on the same
        # connection). ActionCable's own #subscribed/#unsubscribed are
        # private on the base class, so they are never subtracted by
        # super — but a public app-side override is added straight back by
        # public_instance_methods(false), which is the hole this closes.
        def internal_methods = super + %i[build_graph subscribed unsubscribed]
      end

      # ActionCable's single dispatch point for incoming actions. The whole
      # action body is posted to the graph's thread and wrapped in one
      # batch — cable threads never touch the graph. Spike-verified: batch
      # per action is all the coalescing the replace-partial style needs.
      #
      # `rescue_from` handlers still run (dispatch_action applies them
      # inside the job, now on the graph thread); what they don't handle
      # propagates to the actor's on_error — ::Rails.error by default.
      def perform_action(data)
        # A nil actor means the subscription was rejected or already torn
        # down; drop the action rather than blow up the cable thread.
        @__hibiki_actor&.post { Hibiki.batch { super(data) } }
      end

      private

      def subscribed
        super
        return reject if cid.blank?

        @__hibiki_actor = build_graph_actor
        # The block runs owned + untracked (Hibiki.root); the effects it
        # creates do their dependency-collecting first run right here, on
        # the graph thread.
        @__hibiki_actor.post { @__hibiki_root = Hibiki.root { build_graph } }
        Hibiki::Rails.registry.register(self)
      end

      # ActionCable calls this even after a rejected subscription — hence
      # the guard. Queue#close inside GraphActor#stop lets the posted
      # dispose drain before the worker exits.
      def unsubscribed
        super
        return unless @__hibiki_actor

        Hibiki::Rails.registry.unregister(self)
        @__hibiki_actor.post { @__hibiki_root.dispose }
        @__hibiki_actor.stop
      end

      # Build the signal graph: create states/deriveds/effects as instance
      # variables so actions can reach them. Runs once, on the graph's
      # thread, inside Hibiki.root.
      def build_graph
        raise NotImplementedError, "#{self.class} must implement #build_graph"
      end

      # The channel half of a single reactive value (see Helpers#reactive for
      # the placeholder half): wraps the block in an effect that transmits
      # `{ value: { name:, text: } }` — the packaged client writes the text
      # into every `[data-hibiki-value=NAME]` placeholder on the page (part
      # of the data-hibiki wire contract, versioned with the client). Call
      # from #build_graph; the block tracks whatever signals it reads (state,
      # derived, or an expression over several). Values are text, never
      # markup: the client assigns textContent, so nothing is interpreted as
      # HTML. Returns the effect, owned by the graph root like any other.
      #
      # Equality-gated: an effect re-runs whenever ANY signal it read
      # changed, so a bumped db_version re-sent every value's text even when
      # the text was byte-identical — once per reactive value, per ping.
      # The block is still called unconditionally, so dependency collection
      # is untouched; only the transmit is skipped.
      #
      # NOTE for placeholders rendered INSIDE a broadcast-replaced fragment:
      # render them with their CURRENT value, not a static default. The swap
      # resets the DOM text, and this gate now suppresses the re-send that
      # used to heal it. Placeholders outside the replaced fragment (a nav
      # badge, controls that are never re-rendered) are unaffected.
      def transmit_value(name, &compute)
        name = Helpers.value_name(name)
        last = Object.new # never == a String, so the first run always sends
        Hibiki::Effect.new do
          text = compute.call.to_s
          unless text == last
            last = text
            transmit({ value: { name:, text: } })
          end
        end
      end

      # Per-page-load graph identity, supplied by the page's subscription
      # (each tab is its own graph). Override to derive identity elsewhere.
      def cid = params[:cid]

      # Streamables the channel broadcasts to, matching the page's
      #   <%= turbo_stream_from channel_name, cid %>
      # Override when the page uses different streamables.
      def stream_name = [channel_name, cid]

      # Seam for a future pooled executor with per-graph ordering; today,
      # one worker thread per graph.
      def build_graph_actor = GraphActor.new(name: "hibiki-#{channel_name}"[0, 15])

      # The channel's graph executor, for helpers that schedule work back
      # onto the graph thread (Broadcasts#broadcast_refresh_effect).
      def graph_actor = @__hibiki_actor
    end
  end
end
