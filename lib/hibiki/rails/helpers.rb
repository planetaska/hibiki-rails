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
    #     form(**on(:add, event: :submit)) { ... }
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
      private_constant :VALUE_NAME, :VALUE_TAG

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

      # The island root: one channel subscription per island, identified by
      # a per-page-load cid (each tab is its own graph). `channel` is the
      # channel class or its name as a string.
      def hibiki_island(channel, cid:)
        channel_name = channel.is_a?(Class) ? channel.name : channel.to_s
        { data: { controller: "hibiki", hibiki_channel_value: channel_name,
                  hibiki_cid_value: cid } }
      end

      # Forward a DOM event on this element as a channel action. `event:`
      # picks the DOM event (:click, :change, :submit); `with:` is a hash
      # sent as the action's payload. The client adds event-derived data on
      # top: a changed control contributes `{ name => value }`, a submitted
      # form contributes its FormData (and is reset after the perform).
      def on(action, event: :click, with: nil)
        data = { hibiki_on: "#{event}->#{action}" }
        data[:hibiki_with] = JSON.generate(with) unless with.nil?
        { data: }
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
    end
  end
end
