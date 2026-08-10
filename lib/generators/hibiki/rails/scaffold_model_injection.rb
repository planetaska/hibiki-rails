# frozen_string_literal: true

module Hibiki
  module Rails
    module Generators
      # What the scaffold writes INTO a model the app already owned: the
      # after_commit ping, which is what makes another tab, another user, the
      # plain controller and a console write all reach an open list.
      #
      # Printing it instead and hoping fails silently: everything works in
      # one tab, which is exactly what makes the absence hard to notice.
      module ScaffoldModelInjection
        private

        def ping_marker = "#{collection_channel_class_name}::CHANGED"
        def route_declared? = wired?("config/routes.rb", "resources :#{plural_name}")

        # Thor anchors inject_into_class on /class #{klass}\n|class #{klass} .*\n/,
        # so the anchor has to be spelled the way the FILE spells it.
        # `class Admin::Book < ApplicationRecord` — what Rails' own model
        # template writes outside an isolated engine — contains no "class Book ",
        # and the nested `module Admin` / `class Book` form contains no
        # "class Admin::Book". Guessing wrong is not an error: Thor prints one
        # red `unchanged` line, writes the file back byte-identical, and the
        # caller goes on to announce a modification that never happened.
        def inject_into_model(path, full_name, snippet)
          anchor = wired?(path, /^\s*class #{Regexp.escape(full_name)}\b/) ? full_name : full_name.demodulize

          inject_into_class path, anchor, snippet
        end

        # Trailing newline on purpose: inject_into_class splices this in right
        # after the class line, so without it the injection butts straight up
        # against whatever the model already declared.
        def model_support
          "#{ping_callback.indent(2)}\n"
        end

        def ping_callback
          <<~RUBY
            # Two streamables:
            # collection ping every index listens to, and a per-record ping
            # the record's show page listens to.
            #
            # Caveats: update_all / insert_all / update_column and
            # raw SQL never fire this.
            after_commit do
              ActionCable.server.broadcast(#{collection_channel_class_name}::CHANGED, {})
              ActionCable.server.broadcast(#{member_channel_class_name}.changed(id), {})
            end
          RUBY
        end

        def announce_model_change
          say_status :inject, "#{model_path} — the after_commit broadcast", :green
          say <<~NOTE

            #{model_path} already existed and was MODIFIED.
          NOTE
        end
      end
    end
  end
end
