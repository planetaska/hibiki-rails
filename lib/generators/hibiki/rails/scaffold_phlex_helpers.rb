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
        # What `bin/rails g phlex:install` leaves behind, and what generated
        # components need from it: a base class to inherit, and an autoloader
        # that maps app/views onto the Views namespace.
        PHLEX_BASE = "app/views/base.rb"
        PHLEX_INITIALIZER = "config/initializers/phlex.rb"
        PHLEX_NAMESPACE = /namespace:\s*Views\b/

        # Rails helper -> the phlex-rails module that adapts it. Mostly
        # `camelize`, with the two exceptions that gem's own REDIRECTS table
        # names: check_box_tag lives under CheckboxTag and text_area_tag under
        # TextAreaTag. Both spellings resolve — REDIRECTS installs a
        # const_missing — but the alias is the one phlex-rails calls legacy, so
        # generated code should not be written in it.
        HELPER_MODULES = {
          check_box_tag: "CheckboxTag",
          text_area_tag: "TextAreaTag"
        }.freeze

        # What Phlex's #plain renders without help. It handles String, Symbol,
        # Integer and Float and RAISES on anything else — deliberately, so a
        # stray object cannot land on the page as "#<Foo:0x…>". ERB's <%= %>
        # simply called to_s, so this is the one place the port cannot be a
        # transliteration: a date, a time or a decimal column needs an explicit
        # to_s or the page raises the first time it renders.
        PLAIN_TYPES = %i[string text integer float].freeze

        private

        def helper_module(helper) = HELPER_MODULES.fetch(helper) { helper.to_s.camelize }

        # `include Phlex::Rails::Helpers::X` for each Rails helper a component
        # calls, plus Hibiki's own when it stamps the protocol. Per component
        # and explicit, never injected into the app's Views::Base: Helpers says
        # so itself ("the gem never includes it for you"), and a component's
        # include list is the most honest statement of what it actually uses.
        #
        # Routes is deliberately absent — phlex:install's Components::Base
        # already includes it, so every component has path helpers.
        def phlex_includes(*helpers, hibiki: false, indent: 2)
          mods = helpers.compact.uniq.map { "#{' ' * indent}include Phlex::Rails::Helpers::#{helper_module(it)}" }
          mods.unshift("#{' ' * indent}include Hibiki::Rails::Helpers") if hibiki
          mods.join("\n")
        end

        # The field helpers this resource's columns actually need, so a form
        # with no date column does not include DateFieldTag.
        def row_field_helper_modules
          schema.columns.reject(&:belongs_to?).map(&:tag_field_helper).uniq
        end

        # Warn, never fail — the scaffold may legitimately come before
        # `bundle add phlex-rails`, and refusing to write anything would leave
        # the user with no output to fix.
        #
        # Two probes because they answer different questions and only the
        # second one bites. A successful require proves the GEM is in the
        # bundle and proves nothing about this app: without base.rb and the
        # initializer's push_dir, Views::Books::Index is not autoloadable and
        # Views::Base does not exist, so every generated page raises NameError
        # at its first request — silent until then, like every other notice
        # this generator prints.
        def warn_without_phlex_rails
          return unless phlex?

          warn_missing_phlex_gem
          warn_missing_phlex_install
        end

        def warn_missing_phlex_gem
          require "phlex/rails"
        rescue LoadError
          say_status :warn, "phlex-rails is not in this bundle. " \
                            'Add `gem "phlex-rails"`, then run ' \
                            "`bin/rails g phlex:install`", :yellow
        end

        def warn_missing_phlex_install
          return if exists?(PHLEX_BASE) && wired?(PHLEX_INITIALIZER, PHLEX_NAMESPACE)

          say_status :warn, "phlex:install has not run. Run: " \
                            "bin/rails g phlex:install", :yellow
        end

        # An overlay run does not clean up after the layer it replaced: a
        # generator never deletes, so the ERB templates stay on disk and stay
        # resolvable. Nothing renders them once the controller names components
        # instead, so they are dead rather than broken — which is exactly why
        # they need saying out loud.
        def stale_erb_views_notice
          return unless phlex?

          stale = Dir[File.join(destination_root, view_dir, "*.html.erb")].map { File.basename(it) }
          return if stale.empty?

          say_status :views, "#{view_dir} still holds the ERB templates a previous run wrote " \
                             "(#{stale.sort.join(', ')}). Nothing renders them now, " \
                             "you can safely delete them.", :yellow
        end

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
        #
        # LAYOUT: FALSE is not optional. turbo-rails renders a broadcast with
        # ApplicationController.render, and a partial: never takes a layout
        # while a renderable: does — so without this every broadcast ships the
        # whole page shell wrapped around the fragment. Measured on a generated
        # app: 885 bytes against 138. It does not raise and the round trip
        # still appears to work, because the extra wrapper is parsed away
        # inside Turbo's <template> and idiomorph still finds the id it wants.
        def list_broadcast_source(indent:)
          return %(partial: "#{partial_path('list')}",\n#{' ' * indent}locals: list_locals) unless phlex?

          "renderable: #{view_class_name(:list)}.new(**list_locals), layout: false"
        end

        def row_broadcast_source(indent:)
          locals = "#{singular_name}: row, actions: false"
          pad = " " * indent
          return "renderable: #{view_class_name(:row)}.new(#{locals}),\n#{pad}layout: false" if phlex?

          %(partial: "#{partial_path(row_partial)}",\n#{pad}locals: { #{locals} })
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

        # ---- emitting Phlex ---------------------------------------------------

        # A column's value, with a to_s only where Phlex needs one (see
        # PLAIN_TYPES). A belongs_to counts as plain: its label column is
        # resolved from LABEL_CANDIDATES, which are all text.
        def display_source(column)
          reader = "#{record_ref}.#{column.display_reader}"
          return reader if column.belongs_to? || PLAIN_TYPES.include?(column.type)

          "#{reader}.to_s"
        end

        # An element call's arguments, parentheses INCLUDED — or nothing at
        # all when there are none. This is what css_attr bought on the ERB side
        # and Phlex has no equivalent for: `div<%= arg_list(*css_args(:page)) %>`
        # is `div(class: "…") do` when styled and plain `div do` under
        # --css=none, where `div() do` is not what a person writes.
        def arg_list(*args, indent: nil, width: 88)
          args = args.flatten.compact
          return "" if args.empty?
          return "(#{args.join(', ')})" unless indent

          "(#{wrapped_list(args, indent: indent, width: width).lstrip})"
        end

        # hbk_attr as arguments. Always present, for the same reason its
        # attribute always is: the hook is what the transport stylesheet
        # selects on and survives --css=none; the token only dresses it.
        def hbk_args(*hooks, token: nil)
          [%(class: "#{[*hooks, (css(token) if token)].compact.join(' ')}")]
        end

        # `def initialize(...)` and its assignments, from the same [name,
        # default] pairs the ERB side turns into a strict-locals header.
        #
        # A genuine upgrade over that header rather than a translation: Ruby
        # enforces keywords, so a channel broadcasting the wrong local raises
        # at the CALL site with the name in the message, where a partial missing
        # one raised inside the template or rendered blank.
        def initializer_source(params, indent: 2)
          pad = " " * indent
          head = "#{pad}def initialize("
          signature = params.map { |name, default| default ? "#{name}: #{default}" : "#{name}:" }

          [
            "#{head}#{wrapped_list(signature, indent: head.length, width: 96).lstrip})",
            *params.map { |name, _| "#{pad}  @#{name} = #{name}" },
            "#{pad}end"
          ].join("\n")
        end

        # A whole `render Views::Books::Row.new(...)` call. The emitter owns the
        # line, so no template computes a continuation column by hand the way
        # render_indent had to for `<%= render "path", `. `shared:` targets the
        # app-wide Views::Shared components instead of the resource's own.
        def render_call(view, args, indent:, shared: false)
          klass = shared ? "Views::Shared::#{view.to_s.camelize}" : view_class_name(view)
          call = "#{' ' * indent}render #{klass}.new"
          return call if args.empty?

          "#{call}(#{wrapped_list(args, indent: call.length + 1, width: 96).lstrip})"
        end

        # The list's per-row render. `record` is the block variable; everything
        # else is the component's own state, so it reads as an ivar.
        def row_render_args(record)
          ["#{singular_name}: #{record}",
           "editing: #{record}.id == @editing_id",
           "form: @form",
           *schema.belongs_tos.map { "#{it.options_local}: @#{it.options_local}" },
           "extras: @extras"]
        end

        def row_form_render_args
          ["#{singular_name}: @#{singular_name}", "form: @form",
           *schema.belongs_tos.map { "#{it.options_local}: @#{it.options_local}" },
           "extras: @extras"]
        end

        # The first paint's locals, off the same query object the channel's rows
        # derived builds — so first paint and every repaint share one query.
        def index_render_args
          query = "@#{singular_table_name}_query"

          ["#{controller_file_name}: #{query}.rows", "page: #{query}.page",
           "page_count: #{query}.page_count", "remaining: #{query}.remaining"]
        end
      end
    end
  end
end
