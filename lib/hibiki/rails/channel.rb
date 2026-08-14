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
        # Lifecycle hooks, never client-invocable actions. Performing
        # "build_graph" would rebuild the graph and leak the old root;
        # "subscribed" would build a SECOND graph actor on the connection.
        #
        # These need subtracting because ActionCable computes action_methods
        # as "public methods this class adds": #subscribed and #unsubscribed
        # are private on its base class, so they are never subtracted for
        # free, and a public app-side override — the shape the ActiveRecord
        # guide's after_commit bridge invites — is added straight back by
        # public_instance_methods(false).
        HIDDEN_ACTIONS = %w[build_graph subscribed unsubscribed].freeze

        # Subtracted from #action_methods rather than through ActionCable's
        # #internal_methods hook. That hook would work now the floor is 8.0 —
        # it is what #action_methods subtracts — but this is deliberately left
        # alone: it is the fix for a real vulnerability (0.3.0, when the floor
        # still included 7.1/7.2 where #internal_methods is never consulted and
        # an override of it was silently dead code), and it holds on every
        # version either way. Churning security-relevant code for idiom is not
        # a trade worth making.
        def action_methods = super - HIDDEN_ACTIONS
      end

      # ActionCable's single dispatch point for incoming actions. The whole
      # action body is posted to the graph's thread and wrapped in one
      # batch — cable threads never touch the graph. Spike-verified: batch
      # per action is all the coalescing the replace-partial style needs.
      #
      # `rescue_from` handlers still run (dispatch_action applies them
      # inside the job, now on the graph thread); what they don't handle
      # propagates to the actor's on_error — ::Rails.error by default.
      #
      # The client stamps a sequence number under the reserved `hbk` key to
      # get a post-batch ack back, which is what stops its pending
      # indicator. It cannot wait for a render instead: the core's equality
      # gate (hibiki 0.2.0) means an ordinary action — paging to the page
      # you are already on, a search that doesn't change the query, a
      # destroy of a row another tab already deleted — legitimately
      # produces zero bytes, and "clear on the next render" would hang
      # forever. `delete`, not `[]`: the key must not reach the action
      # method's data. No `hbk`, no ack, so a 0.3.0 page keeps working.
      def perform_action(data)
        seq = data.delete("hbk")

        # A nil actor means the subscription was rejected or already torn
        # down; drop the action rather than blow up the cable thread.
        posted = @__hibiki_actor&.post do
          Hibiki.batch { super(data) }
        ensure
          # Hibiki.batch flushes in its own ensure, so effects queued
          # before a raise have run by the time this does — the ack is
          # genuinely post-batch. GraphActor#work rescues around the whole
          # job, so without this a raising action would hang the indicator
          # in exactly the case the user most needs it to stop.
          transmit({ ack: seq }) if seq
        end

        # post yields nil (no actor) or false (queue closed): the block
        # never ran, so neither did its ensure. `dropped` is also what lets
        # the client tell "late" from "never" — nothing is coming for this
        # seq, so it settles immediately rather than waiting out the grace
        # window.
        transmit({ ack: seq, dropped: true }) if seq && !posted
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

      # Mirror graph state into the page's address bar: wraps the block in
      # an effect that transmits `{ url: }`; the packaged client
      # history.replaceState's the bar to it. replaceState, never pushState —
      # the URL is a MIRROR of state, not a history entry, so Back needs no
      # popstate choreography and leaves the page normally. Compute a
      # same-origin path ("/songs?page=2" — the client refuses anything
      # else), and omit params that hold their defaults, or the bar grows
      # noise on the first transmit. Pair it with first-paint code that READS
      # those params (controller + subscribe-params seeding), so the mirrored
      # URL reloads to the state it names. Equality-gated like
      # #transmit_value: re-runs track every signal read, re-sends only when
      # the URL actually moved.
      def transmit_url(&compute)
        last = Object.new
        Hibiki::Effect.new do
          url = compute.call.to_s
          unless url == last
            last = url
            transmit({ url: })
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
