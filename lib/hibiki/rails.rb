# frozen_string_literal: true

# NOTE: for everything under lib/hibiki/rails/ — inside this namespace a bare
# `Rails` constant resolves to Hibiki::Rails, not the framework. Always
# write `::Rails.` when you mean the framework.
module Hibiki
  # Rails glue for hibiki: connection-scoped signal graphs over ActionCable,
  # pushing re-rendered HTML through Turbo Streams.
  module Rails
    # Default per-job error sink for GraphActor: the Rails error reporter,
    # so a raising action shows up wherever the app already sends errors.
    # This is the outer layer of the funnel — a flush error first goes to
    # an app-set Hibiki.error_handler if there is one, and only re-raises
    # into the actor's per-job rescue when there isn't.
    #
    # It ALSO logs, in local environments only. ActiveSupport::ErrorReporter
    # has no subscribers by default, so report alone means a graph-thread
    # exception vanishes completely in a stock app: no log line, no stack,
    # and the only symptom is a fragment that stops updating. That cost real
    # debugging time while the CRUD reference app was built. `local?` is
    # development + test, so production apps — which do have a subscriber —
    # get no duplicate line. Swap the whole thing per graph via
    # GraphActor.new(on_error:) if you want different behaviour.
    def self.default_error_reporter
      lambda do |error|
        if ::Rails.env.local? && ::Rails.logger
          ::Rails.logger.error(
            "[hibiki_rails] #{error.class}: #{error.message}\n" \
            "#{Array(error.backtrace).first(20).join("\n")}"
          )
        end
        ::Rails.error.report(error, handled: true, source: "hibiki_rails")
      end
    end

    # Per-signal comparator for AR records held in signals — pass it as
    # `equals: Hibiki::Rails.record_equals`. AR's #== is class + id, which
    # calls a stale record equal to its edited reload; this compares class +
    # attributes instead, recursing through Arrays, and falls back to == for
    # everything else (nil included). Duck-typed: nothing here names an
    # ActiveRecord constant.
    #
    # Opt-in sugar that makes the snapshot pattern forgiving; "records stop
    # at the boundary" stays the documented default.
    def self.record_equals
      @record_equals ||= ->(prev, current) { record_equal?(prev, current) }
    end

    def self.record_equal?(prev, current)
      if prev.respond_to?(:attributes) && current.respond_to?(:attributes)
        prev.instance_of?(current.class) && prev.attributes == current.attributes
      elsif prev.is_a?(Array) && current.is_a?(Array)
        records_equal?(prev, current)
      else
        prev == current
      end
    end
    private_class_method :record_equal?

    def self.records_equal?(prev, current)
      prev.size == current.size && prev.zip(current).all? { record_equal?(it[0], it[1]) }
    end
    private_class_method :records_equal?
  end
end

require_relative "rails/version"
require_relative "rails/registry"
require_relative "rails/graph_actor"
require_relative "rails/debounce"
require_relative "rails/broadcasts"
require_relative "rails/channel"
require_relative "rails/helpers"
require_relative "rails/reactive_form"
require_relative "rails/swallowed_write_warning"
require_relative "rails/engine"
