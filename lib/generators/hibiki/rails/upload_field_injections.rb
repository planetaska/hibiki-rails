# frozen_string_literal: true

module Hibiki
  module Rails
    module Generators
      # What hibiki:rails:upload_field writes into files the app already owns.
      # Every injection is guarded by a wired? probe, so a re-run is a no-op,
      # and every missing anchor downgrades to a manual_wiring notice rather
      # than a half-edit.
      module UploadFieldInjections
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
        PHLEX_FIELDSET_CLOSE = "      end\n\n      form_actions"
        # Line-anchored for the same reason: a boolean field guards its
        # toggle with the same text two spaces deeper.
        ROW_ACTIONS_ANCHOR_ERB = /^ {4}<% if actions %>/
        ROW_ACTIONS_ANCHOR_PHLEX = "    row_actions if @actions"
        ERB_SUBMIT_DIV = /^  <div>\n    <%= form\.submit/
        PHLEX_PAGE_FIELDS_CALL = /^      fields\(form\)\n/
        # The class's own closing `end` — the only `end` at column zero.
        FILE_END = /^end\n\z/
        # The query's window scope; the lazy middle tolerates any prior chain
        # (the regex backtracks past includes(...)'s own parens).
        QUERY_WINDOW_SCOPE =
          /(def window_scope = self\.class\.window\(apply_sort\()(.*?)(\), page: @page\))/

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

        # ---- the model -------------------------------------------------------

        def inject_model_attachment
          lines = model_attachment_lines
          return if lines.empty?
          return manual_wiring(model_path, lines.join("\n").indent(2)) unless exists?(model_path)

          inject_into_model model_path, class_name, "#{lines.join("\n").indent(2)}\n\n"
        end

        # Two independently guarded pieces, so a model that hand-declares the
        # attachment still gains the remove machinery.
        def model_attachment_lines
          lines = []
          unless wired?(model_path, /^\s*has_one_attached :#{attachment_name}\b/)
            lines << "has_one_attached :#{attachment_name}"
          end
          unless wired?(model_path, /attribute :#{remove_attr}\b/)
            lines << "# The classic form's \"Remove #{attachment_human.downcase}\" checkbox — " \
                     "virtual; a same-submit"
            lines << "# upload wins (attachment_changes carries the pending attach)."
            lines << "attribute :#{remove_attr}, :boolean, default: false"
            lines << "after_save(if: -> { #{remove_attr} && " \
                     "attachment_changes[\"#{attachment_name}\"].nil? }) { #{attachment_name}.purge }"
          end
          lines
        end

        # ---- the preloads ----------------------------------------------------

        # Rows are strict_loading and frozen, so the thumbnail raises without
        # these — on the index AND on show-page repaints (the member channel).
        def inject_query_preload
          return if wired?(query_path, /\.#{with_attached}\b/)

          unless wired?(query_path, QUERY_WINDOW_SCOPE)
            return manual_wiring(query_path, "  # preload the attachment:\n  .#{with_attached}")
          end

          gsub_file(query_path, QUERY_WINDOW_SCOPE) do |match|
            head, scope, tail = match.match(QUERY_WINDOW_SCOPE).captures
            "#{head}#{scope}.#{with_attached}#{tail}"
          end
        end

        def inject_member_channel_preload
          path = member_channel_path
          return if wired?(path, /\.#{with_attached}\b/)

          anchor = /(record = #{Regexp.escape(class_name)}\b[^\n]*?)(\.strict_loading\.find_by\(id: record_id\))/
          return manual_wiring(path, "  # preload the attachment:\n  .#{with_attached}") unless wired?(path, anchor)

          gsub_file(path, anchor) do |match|
            head, tail = match.match(anchor).captures
            "#{head}.#{with_attached}#{tail}"
          end
        end

        # ---- the views -------------------------------------------------------

        def inject_row_form_render
          if phlex?
            inject_component_render
          else
            inject_partial_render
          end
        end

        def inject_partial_render
          path = view_path("_#{row_form_partial}.html.erb")
          line = %(    <%= render "#{partial_path(upload_partial)}", form: form, dom: dom, extras: extras %>\n)
          return if wired?(path, upload_partial)
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
          return if wired?(path, "#{concern_name}.new")
          return manual_wiring(path, line) unless wired?(path, PHLEX_FIELDSET_CLOSE)

          insert_into_file path, line, before: PHLEX_FIELDSET_CLOSE
        end

        # The display line: what the row shows OUTSIDE edit mode, on the index
        # and the show page.
        def inject_row_display
          if phlex?
            inject_component_display
            inject_helper_includes(view_path("row.rb"), :row, "ImageTag", "NumberToHumanSize", "LinkTo")
          else
            inject_partial_display
          end
        end

        def inject_partial_display
          path = view_path("_#{row_partial}.html.erb")
          return if wired?(path, /\.#{attachment_reader}\b/)
          return manual_wiring(path, partial_display_snippet) unless wired?(path, ROW_ACTIONS_ANCHOR_ERB)

          insert_into_file path, "#{partial_display_snippet}\n", before: ROW_ACTIONS_ANCHOR_ERB
        end

        # Every display site binds the attachment to a local and branches nil /
        # variable? / else: an image gets a thumbnail, anything else its
        # filename — decided per blob, so mixed accept lists and wrong-typed
        # files both render.
        def partial_display_snippet
          reader = attachment_reader
          <<~ERB.indent(4)
            <div>
              <strong>#{attachment_human}:</strong>
              <%# #{reader}, never the #{attachment_name} proxy: channel rows are
                  frozen and the proxy memoizes into an ivar (FrozenError). %>
              <% #{reader} = #{singular_name}.#{reader} %>
              <% if #{reader}.nil? %>
                —
              <% elsif #{reader}.blob.variable? %>
                <%= image_tag #{reader}.blob.variant(resize_to_limit: [ 80, 80 ])#{arg_css(:thumb)} %>
              <% else %>
                <%= link_to #{reader}.blob.filename, rails_blob_path(#{reader})#{arg_css(:file_link)} %>
                <span#{css_attr(:muted_inline)}>(<%= number_to_human_size(#{reader}.blob.byte_size) %>)</span>
              <% end %>
            </div>
          ERB
        end

        def inject_component_display
          path = view_path("row.rb")
          return if wired?(path, /\.#{attachment_reader}\b/)
          return manual_wiring(path, component_display_snippet) unless wired?(path, ROW_ACTIONS_ANCHOR_PHLEX)

          insert_into_file path, "#{component_display_snippet}\n", before: ROW_ACTIONS_ANCHOR_PHLEX
        end

        def component_display_snippet
          reader = attachment_reader
          <<~RUBY.indent(4)
            div do
              strong { "#{attachment_human}:" }
              whitespace
              # #{reader}, never the #{attachment_name} proxy: channel rows are
              # frozen and the proxy memoizes into an ivar (FrozenError).
              #{reader} = @#{singular_name}.#{reader}
              if #{reader}.nil?
                plain "—"
              elsif #{reader}.blob.variable?
                image_tag#{arg_list("#{reader}.blob.variant(resize_to_limit: [ 80, 80 ])", *css_args(:thumb))}
              else
                link_to#{arg_list("#{reader}.blob.filename", "rails_blob_path(#{reader})", *css_args(:file_link))}
                whitespace
                span#{arg_list(*css_args(:muted_inline))} { "(\#{number_to_human_size(#{reader}.blob.byte_size)})" }
              end
            end
          RUBY
        end

        # The injected display needs helpers the scaffold's components never
        # did; anchored on the class line, exactly once by construction, one
        # guarded insert per module so an earlier run's file gains only what
        # it lacks.
        def inject_helper_includes(path, view, *helpers)
          helpers.each { inject_helper_include(path, view, it) }
        end

        def inject_helper_include(path, view, helper)
          line = "  include Phlex::Rails::Helpers::#{helper}\n"
          return if wired?(path, line.strip)

          anchor = "class #{view_class_name(view)} < Views::Base\n"
          return manual_wiring(path, line) unless wired?(path, anchor)

          insert_into_file path, line, after: anchor
        end

        # ---- the classic page form -------------------------------------------
        #
        # The degraded path: a NAMED file field with direct_upload — the
        # ActiveStorage.start() form machinery uploads on submit and swaps in
        # the signed id, and the params pass it straight to the writer.

        def inject_page_form
          return if wired?(page_form_view, /file_field[ (]:#{attachment_name}\b/)

          phlex? ? inject_page_form_phlex : inject_page_form_erb
        end

        def inject_page_form_erb
          return manual_wiring(page_form_view, erb_page_snippet) unless wired?(page_form_view, ERB_SUBMIT_DIV)

          insert_into_file page_form_view, "#{erb_page_snippet}\n", before: ERB_SUBMIT_DIV
        end

        def erb_page_snippet
          reader = attachment_reader
          thumb = "#{reader}.blob.variant(resize_to_limit: [ 48, 48 ])"
          size = "number_to_human_size(#{reader}.blob.byte_size)"
          field = "form.file_field :#{attachment_name}, accept: \"#{accept_attr}\", " \
                  "direct_upload: true#{arg_css(:file_input)}"
          [
            "  <%= form.label :#{attachment_name}#{arg_css(:label)} %>",
            "  <% #{reader} = #{singular_name}.#{reader} %>",
            "  <div#{css_attr(:upload_row)}>",
            "    <% if #{reader} && #{reader}.blob.variable? %>",
            "      <%= image_tag #{thumb}#{arg_css(:thumb)} %>",
            "    <% elsif #{reader} %>",
            "      <span#{css_attr(:muted_inline)}><%= #{reader}.blob.filename %> (<%= #{size} %>)</span>",
            "    <% end %>",
            "    <%# direct_upload: ActiveStorage.start()'s form machinery uploads on",
            "        submit and swaps in the signed id. %>",
            "    <%= #{field} %>",
            "  </div>",
            "  <% if #{reader} %>",
            "    <%= form.label :#{remove_attr}#{arg_css(:label)} do %>",
            "      <%= form.checkbox :#{remove_attr}#{arg_css(:checkbox_sm)} %>",
            "      Remove #{attachment_human.downcase}",
            "    <% end %>",
            "  <% end %>",
            ""
          ].join("\n")
        end

        def inject_page_form_phlex
          unless wired?(page_form_view, PHLEX_PAGE_FIELDS_CALL) && wired?(page_form_view, FILE_END)
            return manual_wiring(page_form_view, phlex_page_method)
          end

          insert_into_file page_form_view, "      #{upload_partial}_fields(form)\n",
                           after: PHLEX_PAGE_FIELDS_CALL
          insert_into_file page_form_view, "\n#{phlex_page_method}", before: FILE_END
          inject_helper_includes(page_form_view, :form, "ImageTag", "NumberToHumanSize")
        end

        def phlex_page_method
          reader = attachment_reader
          thumb = "#{reader}.blob.variant(resize_to_limit: [ 48, 48 ])"
          label = "\"\#{#{reader}.blob.filename} (\#{number_to_human_size(#{reader}.blob.byte_size)})\""
          field = "form.file_field :#{attachment_name}, accept: \"#{accept_attr}\", " \
                  "direct_upload: true#{arg_css(:file_input)}"
          [
            "  # The classic #{attachment_name} path: a NAMED field with direct_upload —",
            "  # ActiveStorage.start()'s form machinery uploads on submit and swaps in",
            "  # the signed id.",
            "  def #{upload_partial}_fields(form)",
            "    #{reader} = @#{singular_name}.#{reader}",
            "    form.label :#{attachment_name}#{arg_css(:label)}",
            "    div#{arg_list(*css_args(:upload_row))} do",
            "      if #{reader} && #{reader}.blob.variable?",
            "        image_tag #{thumb}#{arg_css(:thumb)}",
            "      elsif #{reader}",
            "        span#{arg_list(*css_args(:muted_inline))} { #{label} }",
            "      end",
            "      #{field}",
            "    end",
            "    if #{reader}",
            "      form.label :#{remove_attr}#{arg_css(:label)} do",
            "        form.checkbox :#{remove_attr}#{arg_css(:checkbox_sm)}",
            "        whitespace",
            "        plain \"Remove #{attachment_human.downcase}\"",
            "      end",
            "    end",
            "  end",
            ""
          ].join("\n")
        end

        # ---- the controller --------------------------------------------------

        # A scalar append — :cover, not cover: [] (that would be
        # has_many_attached). The lazy /m middle rides past a nested
        # *_attributes group another generator already added.
        def inject_permitted_params
          path = scaffold_controller_path
          return if wired?(path, /:#{remove_attr}\b/)

          addition = ":#{attachment_name}, :#{remove_attr}"
          anchor = /(params\.expect\(#{singular_table_name}: \[.*?)(\s*\]\))/m
          return manual_wiring(path, addition) unless wired?(path, anchor)

          gsub_file(path, anchor) do |match|
            head, tail = match.match(anchor).captures
            "#{head}, #{addition}#{tail}"
          end
        end
      end
    end
  end
end
