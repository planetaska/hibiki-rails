# frozen_string_literal: true

module Hibiki
  module Rails
    module Generators
      # What hibiki:rails:multiselect writes into files the app already owns.
      # Every injection is guarded by a wired? probe, so a re-run is a no-op,
      # and every missing anchor downgrades to a manual_wiring notice rather
      # than a half-edit.
      module MultiselectInjections
        # The anchors, all text the scaffold templates emit verbatim. Thor's
        # insert_into_file replaces EVERY match, so each anchor must occur
        # exactly once in its file — never a bare "  </div>", which the row
        # form closes two blocks with.
        CHANNEL_ANCHOR = "  include Hibiki::Rails::Channel\n"
        # The fieldset's close: the one "  </div>" a blank line follows (the
        # form-actions close runs straight into the ERB end, and a boolean
        # field's wrap closes at four spaces, which a bare-string anchor
        # matched as a substring).
        ERB_FIELDSET_CLOSE = %r{^  </div>\n\n}
        # The whole reactive_attributes statement, continuation lines
        # included: minimal lines up to the first blank one.
        FORM_ANCHOR = /^[ \t]*reactive_attributes\b(?:.*\n)+?\n/
        PHLEX_FIELDSET_CLOSE = "      end\n\n      form_actions"
        # Line-anchored for the same reason: a boolean field guards its
        # toggle with the same text two spaces deeper.
        ROW_ACTIONS_ANCHOR_ERB = /^ {4}<% if actions %>/
        ROW_ACTIONS_ANCHOR_PHLEX = "    row_actions if @actions"

        private

        # ---- the channel -----------------------------------------------------

        def inject_channel_include
          return if wired?(collection_channel_path, "include #{concern_name}")

          unless wired?(collection_channel_path, CHANNEL_ANCHOR)
            return manual_wiring(collection_channel_path, "  include #{concern_name}")
          end

          insert_into_file collection_channel_path, "  include #{concern_name}\n",
                           after: CHANNEL_ANCHOR
        end

        # ---- the form object ---------------------------------------------------

        def inject_form_association
          return if wired?(form_path, /reactive_association :#{association_name}\b/)
          return manual_wiring(form_path, form_snippet) unless wired?(form_path, FORM_ANCHOR)

          insert_into_file form_path, "#{form_snippet}\n", after: FORM_ANCHOR
        end

        def form_snippet
          <<~RUBY.indent(2)
            # The #{association_name} multi-select: an ids signal over the has_many
            # :through. Commit hands the ids to #update, where AR writes the join rows.
            reactive_association :#{association_name}
          RUBY
        end

        # ---- the owner model ---------------------------------------------------

        def inject_owner_associations
          return if association_declared?
          return if wired?(model_path, /^\s*has_many :#{association_name}\b/)
          return manual_wiring(model_path, owner_association_snippet) unless exists?(model_path)

          inject_into_model model_path, class_name, owner_association_snippet
        end

        def owner_association_snippet
          snippet = <<~RUBY
            has_many :#{join_plural}, dependent: :destroy
            has_many :#{association_name}, through: :#{join_plural}
          RUBY

          "#{snippet.indent(2)}\n"
        end

        # ---- the join model ------------------------------------------------------

        # touch: is what carries a join-row write to every open session — it
        # bumps the owner's updated_at, firing the after_commit pings and
        # moving record_equals. A freshly generated join already has it.
        def inject_join_touch
          return if join_missing? # just generated, template carries touch:
          return if wired?(join_model_path, /belongs_to :#{file_name}\b.*touch/)

          unless wired?(join_model_path, /^\s*belongs_to :#{file_name}\b/)
            return manual_wiring(join_model_path, "  belongs_to :#{file_name}, touch: true")
          end

          gsub_file join_model_path, /^(\s*belongs_to :#{file_name}\b[^\n]*)/, '\1, touch: true'
        end

        # ---- the preloads --------------------------------------------------------

        # Rows are strict_loading, so the display line raises without these.
        def inject_query_preload
          inject_includes query_path,
                          with_existing: /matched_scope\.includes\(([^)]*)\)/,
                          without: "apply_sort(matched_scope)",
                          wrapped: "apply_sort(matched_scope.includes(:#{association_name}))"
        end

        def inject_member_channel_preload
          inject_includes member_channel_path,
                          with_existing: /#{class_name}\.includes\(([^)]*)\)\.strict_loading/,
                          without: "#{class_name}.strict_loading",
                          wrapped: "#{class_name}.includes(:#{association_name}).strict_loading"
        end

        # Two emitted shapes: an includes list to extend, or none to start.
        def inject_includes(path, with_existing:, without:, wrapped:)
          return if wired?(path, /includes\([^)]*:#{association_name}\b/)

          if wired?(path, with_existing)
            gsub_file(path, with_existing) { |match| match.sub(")", ", :#{association_name})") }
          elsif wired?(path, without)
            gsub_file path, without, wrapped
          else
            manual_wiring path, "  # preload the multiselect's association:\n  .includes(:#{association_name})"
          end
        end

        # ---- the views -----------------------------------------------------------

        def inject_row_form_render
          if phlex?
            inject_component_render
          else
            inject_partial_render
          end
        end

        def inject_partial_render
          path = view_path("_#{row_form_partial}.html.erb")
          line = %(    <%= render "#{partial_path(multiselect_partial)}", form: form, dom: dom, extras: extras %>\n)
          return if wired?(path, multiselect_partial)
          return manual_wiring(path, line) unless wired?(path, ERB_FIELDSET_CLOSE)

          insert_into_file path, "\n#{line}", before: ERB_FIELDSET_CLOSE
        end

        def inject_component_render
          path = view_path("row_form.rb")
          # Two vintages of row_form: dom became a keyword (@dom) when the
          # form was parameterized for inline create; before that it was a
          # private method.
          dom = wired?(path, "@dom = dom") ? "@dom" : "dom"
          line = "        render #{component_class_name}.new(form: @form, dom: #{dom}, extras: @extras)\n"
          return if wired?(path, "Multiselect.new")
          return manual_wiring(path, line) unless wired?(path, PHLEX_FIELDSET_CLOSE)

          insert_into_file path, line, before: PHLEX_FIELDSET_CLOSE
        end

        # The display line: what the row shows OUTSIDE edit mode, on the index
        # and the show page.
        def inject_row_display
          if phlex?
            inject_component_display
          else
            inject_partial_display
          end
        end

        def inject_partial_display
          path = view_path("_#{row_partial}.html.erb")
          return if wired?(path, ".#{association_name}.map")
          return manual_wiring(path, partial_display_snippet) unless wired?(path, ROW_ACTIONS_ANCHOR_ERB)

          insert_into_file path, "#{partial_display_snippet}\n", before: ROW_ACTIONS_ANCHOR_ERB
        end

        def partial_display_snippet
          <<~ERB.indent(4)
            <div>
              <strong>#{target_human_plural}:</strong>
              <%= #{singular_name}.#{association_name}.map(&:#{label_column}).join(", ").presence || "—" %>
            </div>
          ERB
        end

        def inject_component_display
          path = view_path("row.rb")
          return if wired?(path, ".#{association_name}.map")
          return manual_wiring(path, component_display_snippet) unless wired?(path, ROW_ACTIONS_ANCHOR_PHLEX)

          insert_into_file path, "#{component_display_snippet}\n", before: ROW_ACTIONS_ANCHOR_PHLEX
        end

        def component_display_snippet
          <<~RUBY.indent(4)
            div do
              strong { "#{target_human_plural}:" }
              whitespace
              plain(@#{singular_name}.#{association_name}.map(&:#{label_column}).join(", ").presence || "—")
            end
          RUBY
        end

        # The pre-0.7.0 extras threading moved to ExtrasThreading (shared with
        # hibiki:rails:upload_field).
      end
    end
  end
end
