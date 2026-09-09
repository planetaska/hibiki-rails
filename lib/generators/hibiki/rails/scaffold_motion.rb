# frozen_string_literal: true

module Hibiki
  module Rails
    module Generators
      # Getting the motion module onto the page. The views carry the marks and
      # the class names, the stylesheet carries the rules, and this is the
      # third leg: the client module that holds a render while a marked
      # element's transition runs. Without it everything still works — rows
      # pop instead of sliding — which is exactly the kind of silent gap a
      # notice exists for.
      #
      # One import line, in the file both worlds have: importmap apps resolve
      # it through the engine's pin, bundler apps through the npm package.
      module ScaffoldMotion
        APPLICATION_JS = "app/javascript/application.js"
        MOTION_IMPORT = %(import "hibiki-rails/motion"\n)

        private

        def wire_motion_module
          return unless motion?

          @motion_wiring =
            if wired?(APPLICATION_JS, MOTION_IMPORT.strip)
              :already
            elsif exists?(APPLICATION_JS)
              append_to_file APPLICATION_JS, MOTION_IMPORT
              :import
            else
              :manual
            end
        end

        def motion_notice
          case @motion_wiring
          when :import
            say_status :motion, "#{APPLICATION_JS} now imports hibiki-rails/motion, the client module " \
                                "that lets a marked element finish its transition before a render " \
                                "removes it", :blue
          when :manual
            say_status :motion, "#{APPLICATION_JS} not found, so nothing will slide. Import the motion " \
                                "module from your JavaScript entry point: #{MOTION_IMPORT.strip}", :yellow
          end
        end
      end
    end
  end
end
