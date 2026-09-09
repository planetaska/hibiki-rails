# frozen_string_literal: true

module Hibiki
  module Rails
    module Generators
      # Emitting the app-wide stylesheets, and getting them onto the page.
      #
      # Two of them: the transport stylesheet (the client's loading and
      # connection state) and, when motion is on, the motion stylesheet (the
      # classes the views name). Both key on attributes the client stamps and
      # know nothing about any model, so each is ONE file per app rather than
      # one per resource — which is also why every write here is idempotent:
      # scaffolding a second resource finds it already present and leaves it,
      # and the wiring line it needs is added at most once.
      #
      # Getting a file onto the page is the part with branches, because "the
      # main stylesheet" is not one thing. Three app shapes cover everything
      # the generators have been run against, and the fourth branch is a
      # printed instruction rather than a guess.
      module ScaffoldTransportStylesheet
        DIR = "app/assets/stylesheets"

        # What each file is FOR, in the notice's words: what it does once
        # wired, and what stays broken while it is not. The busy sheet is
        # always installed; the motion sheet only under motion?.
        STYLESHEETS = {
          busy: {
            file: "hibiki_busy.css",
            wired: "It styles the client's loading and connection state, and is shared by every " \
                   "generated resource",
            unwired: "the loading and connection state will be invisible"
          },
          motion: {
            file: "hibiki_motion.css",
            wired: "It defines the motion classes the views name (hbk-slide, hbk-slide-x, hbk-fade, " \
                   "…); duration and easing are tuned there",
            unwired: "nothing will slide"
          }
        }.freeze

        # The busy sheet's names, kept as constants: the specs and the docs
        # refer to them.
        STYLESHEET = "#{DIR}/#{STYLESHEETS.dig(:busy, :file)}".freeze
        LOGICAL_NAME = "hibiki_busy"

        # The LEADING ./ is not decoration. Tailwind 4's CLI resolves imports
        # the way a bundler does, so a bare "hibiki_busy.css" is looked up as a
        # PACKAGE and the build fails with "Can't resolve" — even though the
        # file is sitting next to the entry stylesheet.
        IMPORT_LINE = %(@import "./hibiki_busy.css";)

        # The entry stylesheet a bundler compiles, in the order the two
        # conventions are checked, each with the path an import there needs.
        # cssbundling-rails keeps it beside the other stylesheets;
        # tailwindcss-rails gives it its own directory, so the import has to
        # climb out of it.
        ENTRIES = {
          "app/assets/stylesheets/application.tailwind.css" => "./",
          "app/assets/tailwind/application.css" => "../stylesheets/"
        }.freeze

        LAYOUT = "app/views/layouts/application.html.erb"

        # Propshaft's bulk helper: :app links every css file under app/assets,
        # :all every one on the load path. Either way a new file in that
        # directory is already on the page and there is nothing to wire.
        BULK_LINK = /stylesheet_link_tag\s+:(?:app|all)\b/

        # Anchor for the fallback, and deliberately narrow: it matches the line
        # a stock layout carries so the new tag lands directly after it, in the
        # <head>, where a stylesheet belongs. Never one of OUR tags: Thor's
        # insert_into_file lands after every match, and the second sheet must
        # not land twice.
        SINGLE_LINK = /^.*stylesheet_link_tag\s+(?!"hibiki_)["':].*$\n/

        LINK_TAG = %(    <%= stylesheet_link_tag "hibiki_busy", "data-turbo-track": "reload" %>\n)

        # Where the import lands: directly below Tailwind's own. CSS wants
        # every @import before any other statement, so appending after a
        # `@plugin "daisyui"` line emits invalid CSS — and Tailwind's entry
        # always opens with its own import, which ours must follow anyway. An
        # entry someone rewrote without that line just gets the import
        # appended; assume they will place it themselves. (Order never protects
        # the rules from the utilities — being unlayered does, see the busy
        # stylesheet's own header.)
        TAILWIND_IMPORT = %(@import "tailwindcss";\n)

        private

        def create_transport_stylesheet
          @stylesheet_wiring = {}
          install_stylesheet(:busy)
          install_stylesheet(:motion) if motion?
        end

        # Records what happened for the post-install notice, which is the only
        # place the user learns which branch they landed on.
        def install_stylesheet(key)
          sheet = STYLESHEETS.fetch(key)
          template "#{sheet[:file]}.tt", stylesheet_path(sheet)
          @stylesheet_wiring[key] = wire_stylesheet(sheet)
        end

        def wire_stylesheet(sheet)
          if (entry = ENTRIES.keys.find { exists?(it) })
            import_into_entry(entry, sheet)
          elsif wired?(LAYOUT, BULK_LINK)
            :bulk
          else
            link_from_layout(sheet)
          end
        end

        # The :already probe uses the entry's OWN line, not IMPORT_LINE — the
        # tailwindcss-rails entry imports "../stylesheets/hibiki_busy.css", and
        # probing for the "./" spelling there re-appended on every re-run.
        # A later sheet lands below the one before it, so the entry reads in
        # install order.
        def import_into_entry(entry, sheet)
          line = import_line(entry, sheet)
          return :already if wired?(entry, line)

          anchor = [previous_import(entry, sheet), TAILWIND_IMPORT].compact.find { wired?(entry, it) }
          if anchor
            inject_into_file entry, "#{line}\n", after: anchor
          else
            append_to_file entry, "#{line}\n"
          end
          :import
        end

        # Propshaft serves this file at a digested path, and its only CSS
        # compiler rewrites url(...) — never @import. So an @import appended to
        # a plain application.css resolves to an undigested path and 404s
        # silently, which is why this branch edits the layout instead.
        def link_from_layout(sheet)
          return :already if wired?(LAYOUT, logical_name(sheet))
          return :manual unless exists?(LAYOUT) && wired?(LAYOUT, SINGLE_LINK)

          inject_into_file LAYOUT, link_tag(sheet), after: SINGLE_LINK
          :layout
        end

        def stylesheet_path(sheet) = "#{DIR}/#{sheet[:file]}"
        def logical_name(sheet) = File.basename(sheet[:file], ".css")
        def import_line(entry, sheet) = %(@import "#{ENTRIES.fetch(entry)}#{sheet[:file]}";)
        def link_tag(sheet) = %(    <%= stylesheet_link_tag "#{logical_name(sheet)}", "data-turbo-track": "reload" %>\n)

        # The import line of the sheet installed before this one, or nil.
        def previous_import(entry, sheet)
          keys = STYLESHEETS.keys
          index = keys.index { STYLESHEETS[it] == sheet }
          return nil unless index&.positive?

          "#{import_line(entry, STYLESHEETS[keys[index - 1]])}\n"
        end

        # Which way each sheet reached the page. Two of the four say what was
        # EDITED, because a file this generator touched outside app/{channels,
        # models,forms,views,controllers} should never be a surprise; :bulk
        # and :already edited nothing and say nothing.
        #
        # :manual is the one that fails silently when ignored — the stylesheet
        # is on disk, nothing links it, every indicator is invisible, and
        # nothing raises.
        def stylesheet_notice
          @stylesheet_wiring.each do |key, wiring|
            sheet = STYLESHEETS.fetch(key)
            case wiring
            when :import then say_stylesheet_wired(sheet, "imported from your entry stylesheet")
            when :layout then say_stylesheet_wired(sheet, "linked from #{LAYOUT}")
            when :manual then say_stylesheet_manual(sheet)
            end
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

        def say_stylesheet_wired(sheet, how)
          say_status :css, "#{stylesheet_path(sheet)} was created and #{how}. #{sheet[:wired]}", :blue
        end

        def say_stylesheet_manual(sheet)
          say_status :css, "#{stylesheet_path(sheet)} was created but nothing links it, so " \
                           "#{sheet[:unwired]}. Add it to your layout —\n    " \
                           "#{link_tag(sheet).strip}\n  " \
                           ", or import from your entry stylesheet: " \
                           "#{import_line(ENTRIES.keys.first, sheet)}", :yellow
        end
      end
    end
  end
end
