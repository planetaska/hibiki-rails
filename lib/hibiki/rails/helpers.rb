# frozen_string_literal: true

require "cgi/escape"
require "json"

module Hibiki
  module Rails
    # Opt-in helpers that stamp the packaged client's attribute protocol
    # (interpreted by the vendored hibiki.js Stimulus controller). Strictly
    # opt-in, mirroring Hibiki::DSL: include it where you want the bare
    # names — ApplicationHelper for ERB views, individual Phlex components —
    # the gem never includes it for you.
    #
    #   div(**hibiki_island(CounterChannel, cid:)) do
    #     button(**on(:increment)) { "+" }
    #     button(**on(:toggle, with: { index: 3 })) { "toggle" }
    #     input(name: "step", **on(:set_step, event: :change))
    #     input(name: "q", **on(:search, event: :input))
    #     button(**on(:destroy, confirm: "Are you sure?")) { "delete" }
    #     button(**on(:load_more, event: %i[click visible])) { "more" }
    #     form(**on(:save, event: :submit, reset: false)) { ... }
    #   end
    #
    # Both helpers return a `{ data: { ... } }` hash: splat it into Phlex
    # element methods or Rails tag helpers (`tag.div(**hibiki_island(...))`).
    # When the element needs other attributes on the same `data:` key, merge
    # the hashes yourself (Phlex's `mix` does this).
    #
    # The emitted attribute names are a private contract between these
    # helpers and the gem's JS — they version together; don't hand-write
    # them in app code.
    #
    # #reactive is the exception to the splat shape: it returns a complete
    # placeholder element (`<%= reactive :doubled, 0 %>` in ERB). Phlex
    # components splat instead: `span(**reactive_attrs(:doubled))`.
    module Helpers
      # A reactive value's name lands in an attribute selector on both
      # halves, so keep it to safe characters; the placeholder tag name
      # lands in raw markup, so allowlist it too.
      VALUE_NAME = /\A[a-z][a-z0-9_-]*\z/i
      VALUE_TAG = /\A[a-z][a-z0-9-]*\z/i

      # Event and action names share the hibiki_on attribute, which is a
      # whitespace-separated token list — a name carrying a space or an
      # arrow would silently change what the client dispatches. The dot is
      # allowed so a future event qualifier (keydown.enter) needs no second
      # grammar change.
      EVENT_NAME = /\A[a-z][a-z0-9_.-]*\z/i

      # Per-keystroke round trips are the failure mode #on exists to avoid,
      # so :input carries a debounce unless the caller says otherwise. It is
      # applied here rather than in the client, so the number is visible in
      # the emitted markup instead of being an invisible default.
      DEFAULT_INPUT_DEBOUNCE = 250

      private_constant :VALUE_NAME, :VALUE_TAG, :EVENT_NAME

      # The shared name validator for both halves of a reactive value (the
      # view-side data-hibiki-value placeholder and the channel's
      # #transmit_value message).
      def self.value_name(name)
        name = name.to_s
        unless VALUE_NAME.match?(name)
          raise ArgumentError,
                "reactive value name #{name.inspect} must match #{VALUE_NAME.inspect}"
        end
        name
      end

      # The shared validator for both halves of an `event->action` token.
      def self.event_name(name)
        name = name.to_s
        unless EVENT_NAME.match?(name)
          raise ArgumentError,
                "event or action name #{name.inspect} must match #{EVENT_NAME.inspect}"
        end
        name
      end

      # The island root: one channel subscription per island, identified by
      # a per-page-load cid (each tab is its own graph). `channel` is the
      # channel class or its name as a string.
      #
      # `params:` is a hash of extra subscribe params, reaching the channel
      # as `params[:key]` beside `cid`. It is how a channel learns WHICH
      # record its page is about (a show page's `record_id`), which is
      # otherwise unexpressible — the subscription is the only server-side
      # hook that runs before the graph is built.
      #
      # THE TRUST RULE. Subscribe params are client-supplied and untrusted,
      # exactly like query params on a request: anyone can open a socket and
      # send whatever they like. A channel may use one only to LOOK UP A
      # RECORD INSIDE A SCOPE IT CHOOSES ITSELF —
      # `current_user.books.find(params[:record_id])` — and must `reject`
      # when the lookup fails. It must never interpolate a param into a
      # streamable name, a class name, a column name, or a scope. The
      # streamable a channel streams from is always derived server-side from
      # the record it has already loaded and authorized. The client cannot
      # override `channel` or `cid` through this hash.
      def hibiki_island(channel, cid:, params: nil)
        channel_name = channel.is_a?(Class) ? channel.name : channel.to_s
        data = { controller: "hibiki", hibiki_channel_value: channel_name,
                 hibiki_cid_value: cid }
        data[:hibiki_params_value] = JSON.generate(params) unless params.nil?
        { data: }
      end

      # Forward an event on this element as a channel action.
      #
      # `event:` names the event, or a list of them — the left side of the
      # `->` is a hibiki event name, of which DOM events are a subset:
      # :click, :change, :input, :submit, plus the :visible pseudo-event
      # (an IntersectionObserver sentinel — the element entering the
      # viewport). A list makes one element answer several, which is how a
      # load-more button doubles as an infinite-scroll sentinel:
      #
      #   on(:load_more, event: %i[click visible], with: { shown: rows.size })
      #
      # `with:` is a hash sent as the action's payload. The client adds
      # event-derived data on top: a changed control contributes
      # `{ name => value }` — a checkbox its checked state, a multi-select
      # its selected values — and a submitted form contributes its FormData.
      #
      # Everything else is a per-control modifier, kept out of the token
      # grammar so the `->` left side stays purely "which event":
      #
      #   debounce: ms  wait for the gesture to settle before performing.
      #                 :input defaults to DEFAULT_INPUT_DEBOUNCE; pass 0 to
      #                 send every keystroke.
      #   confirm: msg  window.confirm before performing; declining performs
      #                 nothing (and does not submit the form).
      #   reset: false  keep a submitted form's inputs. The default resets
      #                 them, which is right for an "add" form and wrong for
      #                 an edit one — a failed commit would otherwise discard
      #                 what the user typed, synchronously, before the server
      #                 has even replied.
      #   fallback: true  the control's native behavior is its fallback: a
      #                 link's navigation, a form's own action=. While the
      #                 island's link is live the event is intercepted and
      #                 only the channel action fires; any other time —
      #                 scripts absent, still connecting, offline, stalled —
      #                 the client stands aside and the browser does what
      #                 the markup says. This is the progressive-enhancement
      #                 spelling: give the control a real destination (an
      #                 href, an action=), because a bare button has nothing
      #                 to fall back to.
      def on(action, event: :click, with: nil, debounce: nil, confirm: nil, reset: nil,
             fallback: nil)
        action = Helpers.event_name(action)
        events = Array(event).map { Helpers.event_name(it) }
        debounce = DEFAULT_INPUT_DEBOUNCE if debounce.nil? && events.include?("input")
        tokens = events.map { "#{it}->#{action}" }.join(" ")
        { data: { hibiki_on: tokens }
            .merge(on_modifiers(with:, debounce:, confirm:, reset:, fallback:)) }
      end

      # Placeholder for a single reactive value: `<%= reactive :doubled, 0 %>`
      # paints `<span data-hibiki-value="doubled">0</span>`; the channel's
      # `transmit_value(:doubled) { ... }` keeps it fresh. The same value may
      # be placed any number of times, anywhere on the page — every
      # placeholder updates (the client matches document-wide, so a value can
      # render outside its island too). Names must be page-unique across
      # channels. Only the placeholder text is server-rendered: each site
      # keeps its own tag, classes, and attributes across updates.
      def reactive(name, placeholder = "", tag_name: :span)
        tag_name = tag_name.to_s
        unless VALUE_TAG.match?(tag_name)
          raise ArgumentError,
                "reactive value tag #{tag_name.inspect} must match #{VALUE_TAG.inspect}"
        end
        html = %(<#{tag_name} data-hibiki-value="#{Helpers.value_name(name)}">) +
               %(#{CGI.escapeHTML(placeholder.to_s)}</#{tag_name}>)
        html.respond_to?(:html_safe) ? html.html_safe : html
      end

      # The value's attributes, for stamping the placeholder yourself — the
      # Phlex form of #reactive: `span(**reactive_attrs(:doubled)) { "0" }`.
      def reactive_attrs(name) = { data: { hibiki_value: Helpers.value_name(name) } }

      private

      # #on's per-control modifiers, kept out of the token grammar. Each is
      # omitted when it matches the client's own default, so the common call
      # still stamps exactly one attribute.
      def on_modifiers(with:, debounce:, confirm:, reset:, fallback:)
        {
          hibiki_with: (JSON.generate(with) unless with.nil?),
          # nonzero? returns the integer itself, so 0 compacts away.
          hibiki_debounce: (Integer(debounce).nonzero? if debounce),
          hibiki_confirm: confirm&.to_s,
          hibiki_reset: ("false" if reset == false),
          hibiki_fallback: ("true" if fallback)
        }.compact
      end
    end
  end
end
