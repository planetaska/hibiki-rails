# frozen_string_literal: true

module Hibiki
  module Rails
    module Generators
      # Emitting the app-wide view partials — the page control, the
      # field-error line and the form's error summary — into app/views/shared.
      # All three are presentation-only:
      # everything resource-shaped (ids, anchors, page numbers, the message)
      # reaches them as a local or keyword, so they are ONE file per app rather
      # than one per resource, like the transport stylesheet. Every write is
      # idempotent: a second scaffold finds the file present and leaves it.
      #
      # The wrinkle the stylesheet does not have: the emitted BODY depends on
      # --css. Each file carries a "--css=<variant>" marker comment; a run
      # under a different variant keeps the existing file and says so, because
      # silently restyling every other resource's control would be worse.
      module ScaffoldSharedViews
        SHARED_VIEW_DIR = "app/views/shared"

        private

        # Under --infinite-scroll the sentinel is inlined in the list and there
        # is no page control at all — not an empty one. The two error partials
        # are unconditional: every form renders them.
        def create_shared_views
          if phlex?
            create_shared_view("views/pagination.rb.tt", "pagination.rb") unless infinite?
            create_shared_view("views/field_error.rb.tt", "field_error.rb")
            create_shared_view("views/form_errors.rb.tt", "form_errors.rb")
          else
            create_shared_view("views/_pagination.html.erb.tt", "_pagination.html.erb") unless infinite?
            create_shared_view("views/_field_error.html.erb.tt", "_field_error.html.erb")
            create_shared_view("views/_form_errors.html.erb.tt", "_form_errors.html.erb")
          end
        end

        # Skipping an existing file (rather than calling `template` and letting
        # Thor prompt) is what makes the second scaffold's run quiet.
        def create_shared_view(source, basename)
          dest = File.join(SHARED_VIEW_DIR, basename)
          return template(source, dest) unless exists?(dest)

          (@shared_views_kept ||= []) << dest unless wired?(dest, css_marker)
        end

        def css_marker = "--css=#{css_variant}"

        def shared_views_notice
          return if @shared_views_kept.blank?

          say_status :views, "#{@shared_views_kept.join(', ')} #{was_were(@shared_views_kept)} generated " \
                             "with a different --css style and left as is. Delete and re-run to restyle.", :yellow
        end

        # The upgrade path off the per-resource copies. A generator never
        # deletes, so re-running against an app scaffolded before these became
        # shared leaves the old files on disk — dead, because nothing renders
        # them any more. Only this layer's spellings: a --phlex overlay's stale
        # ERB templates are already named by stale_erb_views_notice.
        def stale_shared_views_notice
          basenames = phlex? ? %w[pagination.rb field_error.rb] : %w[_pagination.html.erb _field_error.html.erb]
          stale = basenames.map { view_path(it) }.select { exists?(it) }
          return if stale.empty?

          say_status :views, "#{stale.join(', ')} #{stale.one? ? 'is' : 'are'} left over from before " \
                             "these partials became shared — nothing renders " \
                             "#{stale.one? ? 'it' : 'them'} now, you can safely delete " \
                             "#{stale.one? ? 'it' : 'them'}", :yellow
        end

        def was_were(list) = list.one? ? "was" : "were"
      end
    end
  end
end
