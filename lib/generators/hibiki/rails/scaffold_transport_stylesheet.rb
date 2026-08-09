# frozen_string_literal: true

module Hibiki
  module Rails
    module Generators
      # Emitting the transport stylesheet, and getting it onto the page.
      #
      # The rules key on the client's attributes and know nothing about any
      # model, so this is ONE file per app rather than one per resource — which
      # is also why every write here is idempotent: scaffolding a second
      # resource finds it already present and leaves it, and the wiring line it
      # needs is added at most once.
      #
      # Getting it onto the page is the part with branches, because "the main
      # stylesheet" is not one thing. Three app shapes cover everything the
      # generators have been run against, and the fourth branch is a printed
      # instruction rather than a guess.
      module ScaffoldTransportStylesheet
        STYLESHEET = "app/assets/stylesheets/hibiki_busy.css"
        LOGICAL_NAME = "hibiki_busy"

        # The LEADING ./ is not decoration. Tailwind 4's CLI resolves imports
        # the way a bundler does, so a bare "hibiki_busy.css" is looked up as a
        # PACKAGE and the build fails with "Can't resolve" — even though the
        # file is sitting next to the entry stylesheet.
        IMPORT_LINE = %(@import "./hibiki_busy.css";)

        # The entry stylesheet a bundler compiles, in the order the two
        # conventions are checked. cssbundling-rails keeps it beside the other
        # stylesheets; tailwindcss-rails gives it its own directory, so the
        # import has to climb out of it.
        ENTRIES = {
          "app/assets/stylesheets/application.tailwind.css" => IMPORT_LINE,
          "app/assets/tailwind/application.css" => %(@import "../stylesheets/hibiki_busy.css";)
        }.freeze

        LAYOUT = "app/views/layouts/application.html.erb"

        # Propshaft's bulk helper: :app links every css file under app/assets,
        # :all every one on the load path. Either way a new file in that
        # directory is already on the page and there is nothing to wire.
        BULK_LINK = /stylesheet_link_tag\s+:(?:app|all)\b/

        # Anchor for the fallback, and deliberately narrow: it matches the line
        # a stock layout carries so the new tag lands directly after it, in the
        # <head>, where a stylesheet belongs.
        SINGLE_LINK = /^.*stylesheet_link_tag\s+["':].*$\n/

        LINK_TAG = %(    <%= stylesheet_link_tag "hibiki_busy", "data-turbo-track": "reload" %>\n)

        # Where the import lands: directly below Tailwind's own. CSS wants
        # every @import before any other statement, so appending after a
        # `@plugin "daisyui"` line emits invalid CSS — and Tailwind's entry
        # always opens with its own import, which ours must follow anyway. An
        # entry someone rewrote without that line just gets the import
        # appended; assume they will place it themselves. (Order never protects
        # the rules from the utilities — being unlayered does, see the
        # stylesheet's own header.)
        TAILWIND_IMPORT = %(@import "tailwindcss";\n)

        private

        def create_transport_stylesheet
          template "hibiki_busy.css.tt", STYLESHEET
          wire_transport_stylesheet
        end

        # Records what happened for the post-install notice, which is the only
        # place the user learns which branch they landed on.
        def wire_transport_stylesheet
          @stylesheet_wiring =
            if (entry = ENTRIES.keys.find { exists?(it) })
              import_into_entry(entry)
            elsif wired?(LAYOUT, BULK_LINK)
              :bulk
            else
              link_from_layout
            end
        end

        # The :already probe uses the entry's OWN line, not IMPORT_LINE — the
        # tailwindcss-rails entry imports "../stylesheets/hibiki_busy.css", and
        # probing for the "./" spelling there re-appended on every re-run.
        def import_into_entry(entry)
          line = ENTRIES.fetch(entry)
          return :already if wired?(entry, line)

          if wired?(entry, TAILWIND_IMPORT)
            inject_into_file entry, "#{line}\n", after: TAILWIND_IMPORT
          else
            append_to_file entry, "#{line}\n"
          end
          :import
        end

        # Propshaft serves this file at a digested path, and its only CSS
        # compiler rewrites url(...) — never @import. So an @import appended to
        # a plain application.css resolves to an undigested path and 404s
        # silently, which is why this branch edits the layout instead.
        def link_from_layout
          return :already if wired?(LAYOUT, LOGICAL_NAME)
          return :manual unless exists?(LAYOUT) && wired?(LAYOUT, SINGLE_LINK)

          inject_into_file LAYOUT, LINK_TAG, after: SINGLE_LINK
          :layout
        end

        # Which way it reached the page. Two of the three say what was EDITED,
        # because a file this generator touched outside app/{channels,models,
        # forms,views,controllers} should never be a surprise; :bulk and
        # :already edited nothing and say nothing.
        #
        # :manual is the one that fails silently when ignored — the stylesheet
        # is on disk, nothing links it, every indicator is invisible, and
        # nothing raises.
        def stylesheet_notice
          case @stylesheet_wiring
          when :import then say_stylesheet_wired("imported from your entry stylesheet")
          when :layout then say_stylesheet_wired("linked from #{LAYOUT}")
          when :manual then say_stylesheet_manual
          end

          stale_busy_partial_notice
        end

        # The upgrade path off the <style> partial. A generator never deletes,
        # so re-running against an app scaffolded before 0.5.0 leaves the old
        # partial on disk — dead, because nothing renders it any more, and
        # duplicating rules that now live in the stylesheet. Worth naming: it
        # is inert rather than broken, so nothing else would ever mention it.
        def stale_busy_partial_notice
          stale = view_path("_busy.html.erb")
          return unless exists?(stale)

          say_status :views, "#{stale} is left over from before the transport stylesheet became an " \
                             "asset — nothing renders it now, you can safely delete it", :yellow
        end

        def say_stylesheet_wired(how)
          say_status :css, "#{STYLESHEET} was created and #{how}. It styles the client's loading and " \
                           "connection state, and is shared by every generated resource", :blue
        end

        def say_stylesheet_manual
          say_status :css, "#{STYLESHEET} was created but nothing links it, so the loading and " \
                           "connection state will be invisible. Add it to your layout —\n    " \
                           "#{LINK_TAG.strip}\n  " \
                           ", or import from your entry stylesheet: #{IMPORT_LINE}", :yellow
        end
      end
    end
  end
end
