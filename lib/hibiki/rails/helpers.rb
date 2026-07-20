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
    # components compose the id instead: `span(id: reactive_id(:doubled))`.
    module Helpers
      # A reactive value's name doubles as its DOM id, so keep it to id-safe
      # characters; the tag name lands in raw markup, so allowlist it too.
      VALUE_NAME = /\A[a-z][a-z0-9_-]*\z/i
      VALUE_TAG = /\A[a-z][a-z0-9-]*\z/i
      private_constant :VALUE_NAME, :VALUE_TAG

      # The id scheme shared by the view-side placeholder and the channel's
      # #transmit_value fragment — a Ruby-side view↔channel convention (the
      # client swaps ANY transmitted fragment by id; no JS involvement).
      def self.value_id(name)
        name = name.to_s
        unless VALUE_NAME.match?(name)
          raise ArgumentError,
                "reactive value name #{name.inspect} must match #{VALUE_NAME.inspect}"
        end
        "hibiki-value-#{name}"
      end

      # The full fragment for one reactive value. Values are text, not
      # markup: always escaped, no html_safe opt-out.
      def self.value_tag(name, value, tag_name: :span)
        tag_name = tag_name.to_s
        unless VALUE_TAG.match?(tag_name)
          raise ArgumentError,
                "reactive value tag #{tag_name.inspect} must match #{VALUE_TAG.inspect}"
        end
        %(<#{tag_name} id="#{value_id(name)}">#{CGI.escapeHTML(value.to_s)}</#{tag_name}>)
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
      # paints `<span id="hibiki-value-doubled">0</span>`; the channel's
      # `transmit_value(:doubled) { ... }` keeps it fresh. The name joins the
      # two halves and must be page-unique.
      def reactive(name, placeholder = "", tag_name: :span)
        html = Helpers.value_tag(name, placeholder, tag_name:)
        html.respond_to?(:html_safe) ? html.html_safe : html
      end

      # The value's DOM id, for stamping the placeholder yourself — the Phlex
      # form of #reactive: `span(id: reactive_id(:doubled)) { "0" }`.
      def reactive_id(name) = Helpers.value_id(name)
    end
  end
end
