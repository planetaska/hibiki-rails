# frozen_string_literal: true

module Hibiki
  module Rails
    module Generators
      # What differs between the two view layers OUTSIDE the view templates.
      #
      # The channels and the controller are one template set, not two: they
      # differ by about eight lines across 470, and forking them to change eight
      # would pay the phase's stated maintenance cost — every future change made
      # twice — on the files that have the least to gain from it. So each
      # divergent line is emitted from here instead, and under ERB every method
      # returns exactly the text those templates carried before --phlex existed.
      #
      # The view templates themselves genuinely are two trees (§19.4): a class
      # token map can restyle markup, but nothing short of an HTML-AST DSL can
      # turn `<div id="x">` into `div(id: "x")`.
      module ScaffoldPhlexHelpers
        private

        # phlex-rails' own convention, which its install generator already
        # autoloads: app/views/books/list.rb defines Views::Books::List.
        # controller_class_name is Admin::Books for a namespaced resource and is
        # already what view_dir is built from, so nesting comes free.
        def view_class_name(view) = "Views::#{controller_class_name}::#{view.to_s.camelize}"

        # The render effect's target. `renderable:` is forwarded by
        # broadcast_morph into ApplicationController.render, which calls
        # #render_in with a real view context — so a component may use
        # phlex-rails helpers even though no controller action ran.
        #
        # list_locals returns exactly the keys the component's initializer
        # declares, which is the point of keeping both sides on #list_locals:
        # Ruby raises at the call site if they ever drift, where a partial with
        # a missing local raised inside the template or, worse, rendered blank.
        def list_broadcast_source(indent:)
          return %(partial: "#{partial_path('list')}",\n#{' ' * indent}locals: list_locals) unless phlex?

          "renderable: #{view_class_name(:list)}.new(**list_locals)"
        end

        def row_broadcast_source(indent:)
          locals = "#{singular_name}: row, actions: false"
          unless phlex?
            return %(partial: "#{partial_path(row_partial)}",\n#{' ' * indent}locals: { #{locals} })
          end

          "renderable: #{view_class_name(:row)}.new(#{locals})"
        end

        # An action's render call, or nothing at all.
        #
        # ERB gets nothing because Rails' implicit render already picks the
        # template up from the action's name, and adding an explicit one would
        # move this controller further from `rails g scaffold` output for no
        # gain. A Phlex component is reached by CONSTANT and cannot see a
        # controller's ivars, so every site has to name it and hand it the
        # locals — including the two failure paths, which are the reason there
        # are six sites here and not four.
        def phlex_render(view, indent:, status: nil)
          return "" unless phlex?

          call = "#{view_class_name(view)}.new(#{view_kwargs(view).join(', ')})"
          "#{' ' * indent}render #{call}#{", status: #{status}" if status}\n"
        end

        def view_kwargs(view)
          case view
          when :index then ["#{singular_table_name}_query: @#{singular_table_name}_query"]
          when :show then ["#{singular_name}: @#{singular_table_name}"]
          else ["#{singular_name}: @#{singular_table_name}", *association_kwargs]
          end
        end

        # The belongs_to collections the form offers, named as the controller
        # already assigns them.
        def association_kwargs
          schema.belongs_tos.map do |column|
            plural = column.association_name.to_s.pluralize
            "#{plural}: @#{plural}"
          end
        end
      end
    end
  end
end
