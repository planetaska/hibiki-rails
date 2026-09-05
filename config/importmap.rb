# frozen_string_literal: true

# Merged into the host app's import map by the Engine's importmap
# initializer (importmap-rails reads every path in config.importmap.paths).
# The app supplies the "@hotwired/stimulus" and "@hotwired/turbo-rails" pins
# — both are part of the Rails 8 default stack. The client takes Action
# Cable from turbo-rails' consumer, so no "@rails/actioncable" pin is needed.
pin "hibiki-rails", to: "hibiki.js"
