# frozen_string_literal: true

module Hibiki
  module Rails
    module Generators
      # How a generated view's argument lists are assembled.
      #
      # These live here rather than in the templates because of --css=none. A
      # `<% if css? %>` guard around a `class:` line works, but it forces that
      # argument onto a line of its own and drags everything after it along —
      # the emitted markup then wraps nothing like what a person would write.
      # Building the list in Ruby and wrapping it once keeps --css=none clean
      # AND the styled variants naturally packed.
      #
      # Depends on the generator for #css, #css?, #schema and the naming
      # helpers; it is a mixin, not a standalone object.
      module ScaffoldViewHelpers
        # Which css token dresses a field. The two forms differ by one entry:
        # the classic form_with select is unwidened, the inline one is full
        # width — a difference the hand-built variants have in all three
        # stylesheets, so it is real rather than an oversight.
        FIELD_TOKENS = { string: :input_full, text: :textarea_full, boolean: :toggle }.freeze

        private

        # A whole ` class="..."` attribute, or nothing at all. Under --css=none
        # the attribute is ABSENT, not empty.
        def css_attr(token)
          value = css(token)
          value ? %( class="#{value}") : ""
        end

        # The same decision as an ARGUMENT rather than an attribute: one
        # element, or none. Every argument list below splats it, so --css=none
        # drops the `class:` keyword entirely instead of emitting `class: nil` —
        # which would render an empty attribute and, worse, read as an oversight
        # in a file the user now owns.
        def css_args(token)
          value = css(token)
          value ? [%(class: "#{value}")] : []
        end

        # The one kind of class that survives --css=none: a state hook the
        # transport stylesheet selects on. The hook names what the element IS
        # to the busy machine and is identical in all three variants; the
        # optional token only dresses it. So this attribute is always present,
        # where css_attr's is not.
        def hbk_attr(*hooks, token: nil)
          %( class="#{[*hooks, (css(token) if token)].compact.join(' ')}")
        end

        def field_token(column)
          return :select if column.belongs_to?

          FIELD_TOKENS.fetch(column.type, :input)
        end

        def row_field_token(column)
          return :select_full if column.belongs_to?

          FIELD_TOKENS.fetch(column.type, :input)
        end

        # `min: 1`-style attributes, as Ruby source, from a numericality
        # validator. Empty for a column with no declared bounds — nothing is
        # invented.
        def html_bounds_source(column)
          column.html_bounds.map { |key, value| "#{key}: #{value}" }.join(", ")
        end

        # ---- the inline, channel-backed form ---------------------------------

        def row_field_args(column)
          bounds = html_bounds_source(column)

          [%("#{column.name}"), "form.#{column.name}",
           *(bounds unless bounds.empty?),
           %(id: "\#{dom}_#{column.name}"),
           *css_args(row_field_token(column)),
           %(**on(:set_field, event: :#{column.tag_event}, with: { field: "#{column.name}" }))]
        end

        def row_select_args(column)
          [%("#{column.name}"),
           "options_for_select(#{column.options_local}, form.#{column.name})",
           %(include_blank: "Select #{column.human_name.downcase}"),
           %(id: "\#{dom}_#{column.name}"),
           *css_args(row_field_token(column)),
           %(**on(:set_field, event: :change, with: { field: "#{column.name}" }))]
        end

        # ---- the row's own controls ------------------------------------------

        # Talks to the channel directly rather than through a form submit, so
        # it needs no hidden-field pair.
        def row_toggle_args(column)
          [%("#{column.name}"), %("1"), "#{singular_name}.#{column.name}",
           %(id: "#{row_dom_id_prefix}_\#{#{singular_name}.id}_#{column.name}"),
           *css_args(:toggle_sm),
           %(**on(:set_#{column.name}, event: :change, with: { id: #{singular_name}.id }))]
        end

        def row_button_args(label, action, token, confirm: nil)
          [%("#{label}"), %(type: "button"),
           *css_args(token),
           %(**on(:#{action}, #{%(confirm: "#{confirm}", ) if confirm}with: { id: #{singular_name}.id }))]
        end

        # ---- the controls partial --------------------------------------------

        def search_field_args
          [":query", "nil",
           *css_args(:input),
           %(placeholder: "#{schema.searchable.map { it.to_s.humanize.downcase }.join(' or ')}"),
           "**on(:search, event: :input)"]
        end

        def filter_select_args(column)
          [":#{column.name}",
           %(options_for_select([["Any", ""], ["Yes", "true"], ["No", "false"]])),
           *css_args(:select),
           %(**on(:set_filter, event: :change, with: { column: "#{column.name}" }))]
        end

        def sort_select_tail_args
          [*css_args(:select), "**on(:set_sort, event: :change)"]
        end

        def direction_button_args
          [%(type: "button"),
           *css_args(:btn_ghost),
           %("aria-label": "Reverse sort direction"),
           "**on(:toggle_direction)"]
        end

        # ---- render calls ----------------------------------------------------

        # The partial path a `render` call names, e.g. "admin/books/book".
        def partial_path(name) = "#{view_dir.delete_prefix('app/views/')}/#{name}"

        # Continuation indent for `    <%= render "<path>", ` — four spaces of
        # markup, `<%= render ` and the quoted path plus its comma.
        def render_indent(path) = path.length + 19

        def index_render_locals
          ["#{controller_file_name}: @#{singular_table_name}_query.rows",
           "page: @#{singular_table_name}_query.page",
           "page_count: @#{singular_table_name}_query.page_count",
           "remaining: @#{singular_table_name}_query.remaining"]
        end

        def row_render_locals
          ["#{singular_name}: #{singular_name}",
           "editing: #{singular_name}.id == editing_id",
           "form: form",
           *schema.belongs_tos.map { "#{it.options_local}: #{it.options_local}" }]
        end

        def row_form_render_locals
          ["#{singular_name}: #{singular_name}", "form: form",
           *schema.belongs_tos.map { "#{it.options_local}: #{it.options_local}" }]
        end

        # What the list fragment is handed, as [name, default] pairs — nil
        # default meaning required. Every local carries one except the rows
        # themselves, because a fragment rendered from a channel has no
        # controller context to fall back on: it branches on locals or it
        # branches on nothing.
        #
        # Pairs rather than source text because the two view layers spell this
        # differently — a strict-locals header one side, a keyword initializer
        # the other — and the SET has to stay the same or the channel's
        # broadcast stops matching what the view accepts.
        def list_locals
          [[controller_file_name, nil], %w[page 1], %w[page_count 1], %w[remaining 0],
           %w[editing_id nil], %w[form nil],
           *schema.belongs_tos.map { [it.options_local.to_s, "[]"] }]
        end

        # The strict-locals header for the list fragment.
        def list_locals_signature
          list_locals.map { |name, default| default ? "#{name}: #{default}" : "#{name}:" }.join(", ")
        end
      end
    end
  end
end
