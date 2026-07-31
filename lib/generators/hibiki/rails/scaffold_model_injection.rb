# frozen_string_literal: true

module Hibiki
  module Rails
    module Generators
      # What the scaffold writes INTO a model the app already owned.
      #
      # Two things, and neither is optional. The delegate, because the row
      # partial prints an association's label and the show page hands that
      # partial a live record — without it the show page raises on arrival. And
      # the after_commit ping, because it is what makes another tab, another
      # user, the plain controller and a console write all reach an open list.
      #
      # Printing them instead and hoping fails silently: everything works in
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
          "#{[association_delegates, ping_callback].compact.join("\n").indent(2)}\n"
        end

        def association_delegates
          return if schema.belongs_tos.empty?

          lines = schema.belongs_tos.map do |column|
            "delegate :#{column.label_column}, to: :#{column.association_name}, " \
              "prefix: true, allow_nil: true"
          end

          <<~RUBY
            # The label a belongs_to contributes to the row projection: the
            # association's first string column. Giving the record the same
            # reader the row carries is what lets ONE partial render both — the
            # show page passes the record, the index and the channel's render
            # effect pass projections.
            #{lines.join("\n")}
          RUBY
        end

        def ping_callback
          <<~RUBY
            # Every writer pings — this channel, another user's channel, the
            # plain controller, a console, a job — and every subscribed graph
            # re-queries. after_commit, not after_save, so subscribers only
            # re-read once the data is actually visible. The message carries no
            # payload on purpose: it says the table moved, not what changed.
            #
            # Two streamables, one per grain the app subscribes at: the
            # collection ping every index listens to, and a per-record ping only
            # that record's show page listens to.
            #
            # Caveats worth knowing: update_all / insert_all / update_column and
            # raw SQL never fire this, and the dev `async` cable adapter is
            # in-process only, so a ping from `bin/rails console` reaches nobody.
            after_commit do
              ActionCable.server.broadcast(#{collection_channel_class_name}::CHANGED, {})
              ActionCable.server.broadcast(#{member_channel_class_name}.changed(id), {})
            end
          RUBY
        end

        def announce_model_change
          say_status :inject, "#{model_path} — #{model_change_summary}", :green
          say <<~NOTE

            #{model_path} already existed and was MODIFIED. The after_commit ping is
            what makes another tab, another user, the plain controller and a console
            write all reach an open list — without it everything still works in one
            tab, which is exactly what makes its absence hard to notice.
          NOTE
        end

        def model_change_summary
          parts = ["the after_commit broadcast"]
          parts.unshift("#{schema.belongs_tos.size} delegate(s)") if schema.belongs_tos.any?
          parts.join(" + ")
        end
      end
    end
  end
end
