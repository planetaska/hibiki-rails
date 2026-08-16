# frozen_string_literal: true

module Hibiki
  module Rails
    module Generators
      # What hibiki:rails:nested writes into files the app already owns.
      # Every injection is guarded by a wired? probe, so a re-run is a no-op,
      # and every missing anchor downgrades to a manual_wiring notice rather
      # than a half-edit. Anchors that could collide are line-anchored
      # regexes matching exactly once (Thor's insert_into_file replaces EVERY
      # match, and a bare-string anchor also matches as a substring — the
      # 0.7.0 trap).
      module NestedInjections
        CHANNEL_ANCHOR = "  include Hibiki::Rails::Channel\n"
        # The whole reactive_attributes statement, continuation lines
        # included: minimal lines up to the first blank one.
        FORM_ANCHOR = /^[ \t]*reactive_attributes\b(?:.*\n)+?\n/
        # The class's own closing end — the only `end` at column zero.
        FILE_END = /^end\n\z/
        REMAINING_ANCHOR = /^    @remaining = Hibiki::Derived\.new [^\n]*\n/
        URL_PARAMS_ANCHOR = /^      url_params: query_url_params/
        # The fieldset's close in the ERB row form: the one "  </div>" a
        # blank line follows.
        ERB_FIELDSET_CLOSE = %r{^  </div>\n\n}
        # The fields partial's own outer close — column zero by construction.
        ERB_FIELDS_CLOSE = %r{^</div>\n\z}
        ERB_SUBMIT_DIV = /^  <div>\n    <%= form\.submit/
        PHLEX_FORM_ACTIONS_CALL = /^      form_actions\n/
        PHLEX_FORM_ACTIONS_DEF = /^  def form_actions\n/
        PHLEX_CONTROLS_CALL = /^      controls\n/
        PHLEX_CONTROLS_DEF = /^  def controls\n/
        PHLEX_PAGE_FIELDS_CALL = /^      fields\(form\)\n/

        private

        # ---- the parent model ------------------------------------------------

        def inject_parent_model
          has_many_re = /^\s*has_many :#{association_name}\b/
          lines = []
          if wired?(model_path, has_many_re)
            note_existing_has_many
          else
            scope = ordered? ? "-> { order(:#{position_column}) }, " : ""
            lines << "has_many :#{association_name}, #{scope}dependent: :destroy, " \
                     "inverse_of: :#{singular_name}, index_errors: true"
          end
          unless wired?(model_path, /^\s*accepts_nested_attributes_for :#{association_name}\b/)
            lines << "accepts_nested_attributes_for :#{association_name}, allow_destroy: true"
          end
          return if lines.empty?

          snippet = "#{lines.join("\n").indent(2)}\n"
          return manual_wiring(model_path, snippet) unless exists?(model_path)

          inject_into_model model_path, class_name, snippet
        end

        def note_existing_has_many
          return if wired?(model_path, /has_many :#{association_name}\b[^\n]*index_errors/)

          say_status :model, "has_many :#{association_name} already declared — make sure it " \
                             "carries inverse_of: :#{singular_name}, index_errors: true" \
                             "#{" and an order(:#{position_column}) scope" if ordered?}.", :yellow
        end

        # ---- the parent form -------------------------------------------------

        def inject_form_nested
          unless wired?(form_path, /reactive_nested :#{association_name}\b/)
            return manual_wiring(form_path, form_nested_snippet) unless wired?(form_path, FORM_ANCHOR)

            insert_into_file form_path, "#{form_nested_snippet}\n", after: FORM_ANCHOR
          end
          inject_form_position_stamp if ordered?
        end

        def form_nested_snippet
          <<~RUBY.indent(2)
            # The #{association_name} fieldset: an array of #{child_form_class_name}s, serialized
            # by to_h as #{attributes_key} and persisted in the record's own save.
            reactive_nested :#{association_name}, "#{child_form_class_name}"
          RUBY
        end

        def inject_form_position_stamp
          return if wired?(form_path, "h[:#{attributes_key}]")
          return manual_wiring(form_path, position_stamp_snippet) if wired?(form_path, /^  def to_h\b/)

          insert_into_file form_path, "\n#{position_stamp_snippet}", before: FILE_END
        end

        def position_stamp_snippet
          key = "h[:#{attributes_key}]"
          [
            "  # Visual order = persisted order: #{position_column} is stamped from the",
            "  # array, skipping rows on their way out.",
            "  def to_h",
            "    super.tap do |h|",
            "      #{key}.reject { it[:_destroy] }",
            "      #{' ' * key.length}.each_with_index { |attrs, i| attrs[:#{position_column}] = i + 1 }",
            "    end",
            "  end",
            ""
          ].join("\n")
        end

        # ---- the channel -----------------------------------------------------

        def inject_channel_include
          path = resource_channel_path
          return if wired?(path, "Hibiki::Rails::NestedActions")

          return manual_wiring(path, "  include Hibiki::Rails::NestedActions") unless wired?(path, CHANNEL_ANCHOR)

          insert_into_file path,
                           "  # Path-addressed actions for the reactive_nested fieldsets.\n  " \
                           "include Hibiki::Rails::NestedActions\n",
                           after: CHANNEL_ANCHOR
        end

        # The edit action's fetch preloads the nested tree — hydrate builds
        # the child forms, and unpreloaded walks would N+1.
        def inject_edit_preload
          path = resource_channel_path
          return if wired?(path, /includes\([^)]*#{child_plural}/)

          cls = Regexp.escape(resource_class_name)
          with = /(    record = #{cls})\.includes\(([^)]*)\)(\.find_by\(id: data\["id"\]\))/
          without = /(  def edit\(data\)\n)(    record = #{cls})(\.find_by\(id: data\["id"\]\))/

          if wired?(path, with)
            extend_edit_preload(path, with)
          elsif root_mode? && wired?(path, without)
            gsub_file(path, without) do |match|
              d, head, tail = match.match(without).captures
              "#{d}    # Preloaded so hydrate builds the child forms without N+1.\n" \
                "#{head}.includes(:#{child_plural})#{tail}"
            end
          else
            manual_edit_preload
          end
        end

        def extend_edit_preload(path, with)
          extended = nil
          gsub_file(path, with) do |match|
            head, list, tail = match.match(with).captures
            extended = extend_includes(list)
            extended ? "#{head}.includes(#{extended})#{tail}" : match
          end
          manual_edit_preload unless extended
        end

        # Extending the includes list: a root child appends; a deep child
        # replaces the parent's leaf symbol with a braced hash, which stays
        # valid at any argument position. A parent that is already a hash key
        # is left for the notice — rewriting inside it is not worth the risk.
        def extend_includes(list)
          if root_mode?
            "#{list}, :#{child_plural}"
          elsif list.include?("#{plural_name}:")
            nil
          elsif list.match?(/:#{plural_name}\b/)
            list.sub(/:#{plural_name}\b/, "{ #{plural_name}: :#{child_plural} }")
          end
        end

        def manual_edit_preload
          manual_wiring resource_channel_path,
                        "  # preload the nested children in the edit action's fetch:\n  " \
                        ".includes(#{root_mode? ? ":#{child_plural}" : "#{plural_name}: :#{child_plural}"})"
        end

        # ---- belongs_to option collections -----------------------------------
        #
        # A child's belongs_to needs its option pairs in every open form —
        # the scaffold's only-while-a-form-is-open idiom: a derived in the
        # channel, a gated local in list_locals, and the local threaded down
        # the partial chain to the fields partial. Runs BEFORE the fieldset
        # injection: the threading guards probe for the local's name, and the
        # injected render line would satisfy them vacuously.

        def inject_option_collections
          schema.belongs_tos.each do |column|
            inject_options_derived(column)
            inject_options_local(column)
            thread_options_local(column)
          end
        end

        def inject_options_derived(column)
          path = resource_channel_path
          return if wired?(path, "@#{column.options_local}")
          return manual_wiring(path, options_derived_snippet(column)) unless wired?(path, REMAINING_ANCHOR)

          insert_into_file path, "\n#{options_derived_snippet(column)}", after: REMAINING_ANCHOR
        end

        def options_derived_snippet(column)
          <<~RUBY.indent(4)
            # One collection per belongs_to, only read while a form is open.
            @#{column.options_local} = Hibiki::Derived.new do
              @db_version.value
              #{column.association_class_name}.order(:#{column.label_column}).pluck(:#{column.label_column}, :id)
            end
          RUBY
        end

        def inject_options_local(column)
          path = resource_channel_path
          local = column.options_local
          return if wired?(path, /^\s*#{local}:/)

          line = "      #{local}: (#{options_gate} ? @#{local}.value : []),\n"
          return manual_wiring(path, line) unless wired?(path, URL_PARAMS_ANCHOR)

          insert_into_file path, line, before: URL_PARAMS_ANCHOR
        end

        def options_gate
          if wired?(resource_channel_path, "@creating")
            "(editing_id || @creating.value)"
          else
            "editing_id"
          end
        end

        def thread_options_local(column)
          local = column.options_local.to_s
          phlex? ? thread_local_phlex(local) : thread_local_erb(local)
        end

        def thread_local_erb(local)
          [list_view, row_view, row_form_view].each do |path|
            next if wired?(path, "#{local}:")

            gsub_file path, ", extras: {}) -%>", ", #{local}: [], extras: {}) -%>", verbose: false
            gsub_file path, "extras: extras", "#{local}: #{local}, extras: extras", verbose: false
          end
          thread_local_ancestors(local)
        end

        def thread_local_phlex(local)
          [list_view, row_view, row_form_view].each do |path|
            next if wired?(path, "#{local}:")

            gsub_file path, /(def initialize\([^)]*?), extras: \{\}\)/m,
                      "\\1, #{local}: [], extras: {})", verbose: false
            gsub_file path, /^(\s*)@extras = extras$/,
                      "\\1@#{local} = #{local}\n\\1@extras = extras", verbose: false
            gsub_file path, "extras: @extras", "#{local}: @#{local}, extras: @extras", verbose: false
          end
          thread_local_ancestors(local)
        end

        # Deep mode: the local also rides through every fields partial
        # between the row form and the parent — each hop's header, and the
        # render call that hands it down.
        def thread_local_ancestors(local)
          fields_chain.each do |(sing, partial)|
            thread_ancestor_header(partial, local)
            thread_ancestor_render(sing, local)
          end
        end

        def thread_ancestor_header(partial, local)
          return if wired?(partial, "#{local}:")

          if phlex?
            gsub_file partial, /(def initialize\([^)]*?), index: 0, count: 1\)/m,
                      "\\1, #{local}: [], index: 0, count: 1)", verbose: false
            gsub_file partial, /^(\s*)@index = index$/,
                      "\\1@#{local} = #{local}\n\\1@index = index", verbose: false
          else
            gsub_file partial, ", index: 0, count: 1) -%>",
                      ", #{local}: [], index: 0, count: 1) -%>", verbose: false
          end
        end

        def thread_ancestor_render(sing, local)
          renderer = fields_renderer(sing)
          return unless renderer

          if phlex?
            component = "#{resource_views_module}::#{sing.camelize}Fields"
            return if wired?(renderer, "#{local}: @#{local}")

            gsub_file renderer, "render #{component}.new(",
                      "render #{component}.new(#{local}: @#{local}, ", verbose: false
          else
            return if wired?(renderer, "#{local}: #{local}")

            gsub_file renderer, %(render "#{resource_path}/#{sing}_fields", ),
                      %(render "#{resource_path}/#{sing}_fields", #{local}: #{local}, ), verbose: false
          end
        end

        # The fields partials from the parent up to (excluding) the row form,
        # as [singular, path] pairs — every hop an options local rides
        # through. Empty at the root, where the standard three cover it.
        def fields_chain
          return [] if root_mode?

          @fields_chain ||= begin
            chain = []
            current = singular_name
            while chain.size < 9 && (partial = existing_fields_partial(current))
              chain << [current, partial]
              base = fields_renderer(current)&.then { File.basename(it) }
              match = base&.match(/\A_?(\w+?)_fields\./)
              break unless match

              current = match[1]
            end
            chain
          end
        end

        def existing_fields_partial(sing)
          rel = resource_view(phlex? ? "#{sing}_fields.rb" : "_#{sing}_fields.html.erb")
          rel if exists?(rel)
        end

        # Which view renders a fields partial: the row form, or a fields
        # partial one level up.
        def fields_renderer(sing)
          file_needle = "#{sing}_fields"
          content_needle = phlex? ? "#{sing.camelize}Fields" : "#{sing}_fields"

          Dir[File.join(destination_root, resource_view_dir, phlex? ? "*.rb" : "*.erb")].find do |f|
            next false if File.basename(f).include?(file_needle)

            File.read(f).include?(content_needle)
          end&.delete_prefix("#{destination_root}/")
        end

        # ---- the container fieldset ------------------------------------------

        def inject_container_fieldset
          needle = phlex? ? "#{child_singular.camelize}Fields" : "#{child_singular}_fields"
          return if wired?(container_view, needle)

          phlex? ? inject_container_fieldset_phlex : inject_container_fieldset_erb
        end

        def inject_container_fieldset_erb
          if root_mode?
            return manual_wiring(container_view, erb_fieldset_snippet) unless wired?(container_view, ERB_FIELDSET_CLOSE)

            insert_into_file container_view, "#{erb_fieldset_snippet}\n", after: ERB_FIELDSET_CLOSE
          else
            return manual_wiring(container_view, erb_fieldset_snippet) unless wired?(container_view, ERB_FIELDS_CLOSE)

            insert_into_file container_view, "\n#{erb_fieldset_snippet}", before: ERB_FIELDS_CLOSE
          end
        end

        def inject_container_fieldset_phlex
          call_anchor = root_mode? ? PHLEX_FORM_ACTIONS_CALL : PHLEX_CONTROLS_CALL
          def_anchor = root_mode? ? PHLEX_FORM_ACTIONS_DEF : PHLEX_CONTROLS_DEF
          unless wired?(container_view, call_anchor) && wired?(container_view, def_anchor)
            return manual_wiring(container_view, phlex_fieldset_method)
          end

          if root_mode?
            insert_into_file container_view, "      #{child_plural}_fieldset\n\n", before: call_anchor
          else
            insert_into_file container_view, "      #{child_plural}_fieldset\n", after: call_anchor
          end
          insert_into_file container_view, "#{phlex_fieldset_method}\n", before: def_anchor
        end

        def container_comment_erb
          if root_mode?
            ["  <%# The nested #{child_plural} fieldset. Rows are addressed by path",
             %(      ("#{child_plural}/<key>"), routed by the generic nested_* actions; the graph),
             "      owns the array, so add/remove never touch the submit payload. %>"]
          else
            ["  <%# The nested #{child_plural} — same pattern one level down; the path just",
             "      grows another association/key pair. %>"]
          end
        end

        def erb_fieldset_snippet
          var = child_singular
          visible = "visible_#{child_plural}"
          partial = "#{resource_path}/#{child_singular}_fields"
          prefix = %(      <%= render "#{partial}", )
          args = ["#{var}: #{var}", "dom: dom", "path: #{child_path_source(var)}",
                  *schema.belongs_tos.map { "#{it.options_local}: #{it.options_local}" },
                  "index: index", "count: #{visible}.size"]
          button = ["tag.button(\"Add #{child_human_singular.downcase}\"", %(type: "button"),
                    *css_args(:btn_outline_sm)].join(", ")

          [*container_comment_erb,
           "  <fieldset#{css_attr(:fieldset)}>",
           "    <legend#{css_attr(:fieldset_legend)}>#{child_human_plural}</legend>",
           "    <% #{visible} = #{parent_form_ref}.#{association_name}.reject(&:marked_for_destruction?) %>",
           "    <% #{visible}.each_with_index do |#{var}, index| %>",
           "#{prefix}#{wrapped_list(args, indent: prefix.length, width: 76).lstrip} %>",
           "    <% end %>",
           "    <%= #{button},",
           "                   **on(:nested_add, with: { dom: dom, path: #{collection_path_source} })) %>",
           "  </fieldset>",
           ""].join("\n")
        end

        def phlex_fieldset_method
          var = child_singular
          prefix = "        render #{fields_component_class_name}.new("
          args = ["#{var}: #{var}", "dom: @dom", "path: #{child_path_source(var)}",
                  *schema.belongs_tos.map { "#{it.options_local}: @#{it.options_local}" },
                  "index: index", "count: visible.size"]
          comment = if root_mode?
                      ["  # The nested #{child_plural} fieldset. Rows are addressed by path",
                       %(  # ("#{child_plural}/<key>"), routed by the generic nested_* actions; the),
                       "  # graph owns the array, so add/remove never touch the submit payload."]
                    else
                      ["  # The nested #{child_plural} — same pattern one level down; the path",
                       "  # just grows another association/key pair."]
                    end

          add_on = "**on(:nested_add, with: { dom: @dom, path: #{collection_path_source} })"

          [*comment,
           "  def #{child_plural}_fieldset",
           "    fieldset#{arg_list(*css_args(:fieldset))} do",
           "      legend#{arg_list(*css_args(:fieldset_legend))} { \"#{child_human_plural}\" }",
           "      visible = #{parent_form_ref}.#{association_name}.reject(&:marked_for_destruction?)",
           "      visible.each_with_index do |#{var}, index|",
           "#{prefix}#{wrapped_list(args, indent: prefix.length, width: 92).lstrip})",
           "      end",
           "      button(type: \"button\"#{css_args(:btn_outline_sm).map { ", #{it}" }.join},",
           "             #{add_on}) { \"Add #{child_human_singular.downcase}\" }",
           "    end",
           "  end",
           ""].join("\n")
        end

        # ---- the classic page form -------------------------------------------
        #
        # The degraded path: fields_for over the existing rows, _destroy via
        # accepts_nested_attributes_for. Adding rows needs the live inline
        # form — no dynamic add here.

        def inject_page_form
          return if wired?(page_form_view, /fields_for[ (]:#{association_name}\b/)

          phlex? ? inject_page_form_phlex : inject_page_form_erb
        end

        def inject_page_form_erb
          if root_mode?
            return manual_wiring(page_form_view, erb_page_snippet) unless wired?(page_form_view, ERB_SUBMIT_DIV)

            insert_into_file page_form_view, "#{erb_page_snippet}\n", before: ERB_SUBMIT_DIV
          else
            anchor = /^([ \t]*)<%= #{parent_builder_var}\.label :_destroy/
            return manual_wiring(page_form_view, erb_page_fieldset(0)) unless wired?(page_form_view, anchor)

            gsub_file(page_form_view, anchor) do |match|
              "#{erb_page_fieldset(match[/\A[ \t]*/].length)}\n#{match}"
            end
          end
        end

        def erb_page_snippet
          ["  <%# The degraded #{child_plural} path: existing rows are editable and a checked",
           "      box destroys on save (_destroy via accepts_nested_attributes_for).",
           "      Adding rows needs the live inline form — no dynamic add here. %>",
           erb_page_fieldset(2),
           ""].join("\n")
        end

        def erb_page_fieldset(indent)
          b = fallback_builder_var
          [
            "<fieldset#{css_attr(:fieldset)}>",
            "  <legend#{css_attr(:fieldset_legend)}>#{child_human_plural}</legend>",
            "  <%= #{parent_builder_var}.fields_for :#{association_name} do |#{b}| %>",
            "    <div#{css_attr(:nested_row)}>",
            *schema.columns.flat_map { erb_page_field_lines(it, b) },
            *(if ordered?
                ["      <%= #{b}.label :#{position_column}#{label_css} %>",
                 "      <%= #{b}.number_field :#{position_column}#{field_css(:input)} %>"]
              end),
            "      <%= #{b}.label :_destroy#{label_css} do %>",
            "        <%= #{b}.checkbox :_destroy %>",
            "        Remove this #{child_human_singular.downcase}",
            "      <% end %>",
            "    </div>",
            "  <% end %>",
            "</fieldset>"
          ].join("\n").indent(indent)
        end

        def erb_page_field_lines(column, builder)
          if column.type == :boolean
            ["      <div#{css_attr(:checkbox_wrap)}>",
             "        <%= #{builder}.label :#{column.name}#{label_css} do %>",
             "          <%= #{builder}.#{column.attr.field_type} :#{column.name}#{field_css(:toggle)} %>",
             "          #{column.human_name}",
             "        <% end %>",
             "      </div>"]
          elsif column.belongs_to?
            collection = "#{column.association_class_name}.order(:#{column.label_column})"
            ["      <%= #{builder}.label :#{column.name}#{label_css} %>",
             "      <%= #{builder}.collection_select :#{column.name}, #{collection}, :id, :#{column.label_column},",
             "            { include_blank: \"Select #{column.human_name.downcase}\" }#{field_css(:select)} %>"]
          else
            bounds = html_bounds_source(column)
            ["      <%= #{builder}.label :#{column.name}#{label_css} %>",
             "      <%= #{builder}.#{column.attr.field_type} :#{column.name}" \
             "#{", #{bounds}" unless bounds.empty?}#{field_css(field_token(column))} %>"]
          end
        end

        def label_css = css? ? %(, class: "#{css(:label)}") : ""
        def field_css(token) = css? ? %(, class: "#{css(token)}") : ""

        def inject_page_form_phlex
          if root_mode?
            unless wired?(page_form_view, PHLEX_PAGE_FIELDS_CALL) && wired?(page_form_view, FILE_END)
              return manual_wiring(page_form_view, phlex_page_method)
            end

            insert_into_file page_form_view, "      #{child_plural}_fields(form)\n",
                             after: PHLEX_PAGE_FIELDS_CALL
            insert_into_file page_form_view, "\n#{phlex_page_method}", before: FILE_END
          else
            anchor = /^([ \t]*)#{parent_builder_var}\.label[ (]:_destroy/
            return manual_wiring(page_form_view, phlex_page_fieldset(0)) unless wired?(page_form_view, anchor)

            gsub_file(page_form_view, anchor) do |match|
              "#{phlex_page_fieldset(match[/\A[ \t]*/].length)}\n#{match}"
            end
          end
        end

        def phlex_page_method
          ["  # The degraded #{child_plural} path: existing rows are editable and a",
           "  # checked box destroys on save (_destroy via",
           "  # accepts_nested_attributes_for). Adding rows needs the live inline",
           "  # form — no dynamic add here.",
           "  def #{child_plural}_fields(form)",
           phlex_page_fieldset(4),
           "  end",
           ""].join("\n")
        end

        def phlex_page_fieldset(indent)
          b = fallback_builder_var
          [
            "fieldset#{arg_list(*css_args(:fieldset))} do",
            "  legend#{arg_list(*css_args(:fieldset_legend))} { \"#{child_human_plural}\" }",
            "  #{parent_builder_var}.fields_for :#{association_name} do |#{b}|",
            "    div#{arg_list(*css_args(:nested_row))} do",
            *schema.columns.flat_map { phlex_page_field_lines(it, b) },
            *(if ordered?
                ["      #{b}.label :#{position_column}#{label_css}",
                 "      #{b}.number_field :#{position_column}#{field_css(:input)}"]
              end),
            "      #{b}.label :_destroy#{label_css} do",
            "        #{b}.checkbox :_destroy",
            "        whitespace",
            "        plain \"Remove this #{child_human_singular.downcase}\"",
            "      end",
            "    end",
            "  end",
            "end"
          ].join("\n").indent(indent)
        end

        def phlex_page_field_lines(column, builder)
          if column.type == :boolean
            ["      div#{arg_list(*css_args(:checkbox_wrap))} do",
             "        #{builder}.label :#{column.name}#{label_css} do",
             "          #{builder}.#{column.attr.field_type} :#{column.name}#{field_css(:toggle)}",
             "          whitespace",
             "          plain \"#{column.human_name}\"",
             "        end",
             "      end"]
          elsif column.belongs_to?
            collection = "#{column.association_class_name}.order(:#{column.label_column})"
            ["      #{builder}.label :#{column.name}#{label_css}",
             "      #{builder}.collection_select :#{column.name}, #{collection}, :id, :#{column.label_column},",
             "            { include_blank: \"Select #{column.human_name.downcase}\" }#{field_css(:select)}"]
          else
            bounds = html_bounds_source(column)
            ["      #{builder}.label :#{column.name}#{label_css}",
             "      #{builder}.#{column.attr.field_type} :#{column.name}" \
             "#{", #{bounds}" unless bounds.empty?}#{field_css(field_token(column))}"]
          end
        end

        # ---- the controller --------------------------------------------------

        # The double-array *_attributes group — a gsub into the existing
        # expect call at the root, nested inside the parent's group deeper.
        def inject_permitted_params
          path = resource_controller_path
          return if wired?(path, "#{attributes_key}:")

          group = "{ #{attributes_key}: [[ #{expect_symbols.join(', ')} ]] }"
          if root_mode?
            anchor = /(params\.expect\(#{singular_table_name}: \[.*?)(\s*\]\))/m
            return manual_wiring(path, group) unless wired?(path, anchor)

            gsub_file(path, anchor) do |match|
              head, tail = match.match(anchor).captures
              "#{head},\n        #{group}#{tail}"
            end
            inject_params_comment
          else
            anchor = /(#{plural_name}_attributes: \[\[.*?:_destroy)/m
            return manual_wiring(path, group) unless wired?(path, anchor)

            gsub_file(path, anchor) { |match| "#{match},\n          #{group}" }
          end
        end

        def expect_symbols
          [":id", *schema.attribute_names.map { ":#{it}" },
           *(":#{position_column}" if ordered?), ":_destroy"]
        end

        def inject_params_comment
          path = resource_controller_path
          return if wired?(path, "double-array")

          gsub_file path,
                    "    # Only allow a list of trusted parameters through.\n",
                    "    # Only allow a list of trusted parameters through. The double-array\n    " \
                    "# shape accepts fields_for's index-keyed *_attributes hashes.\n",
                    verbose: false
        end
      end
    end
  end
end
