# frozen_string_literal: true

module Hibiki
  module Rails
    module Generators
      # The class strings each --css variant stamps into generated views.
      #
      # Substitution happens at GENERATION time, not at render time. Under
      # --css=none the emitted views carry no `class` attribute at all — not an
      # empty one — which a runtime `class="<%= css(:card) %>"` could not
      # produce. That is why templates guard the whole argument line rather
      # than interpolating into it.
      #
      # Transcribed from three hand-built, browser-verified variants in
      # ~/rails_projects/hibiki-crud: 8df15b9 (daisyui), 0bc0319 (tailwind),
      # 51de1e9 (none). 10 of the 11 views differ only in these strings; the
      # page control is the one component whose STRUCTURE differs, and it has
      # per-variant templates instead.
      module CssVariant
        # Plain-Tailwind component strings, named once because they repeat.
        # DaisyUI's own classes are already abstractions, which is why only
        # this side needs the constants.
        SECONDARY_BUTTON = "inline-flex items-center justify-center rounded-md border " \
                           "border-gray-300 bg-white px-3 py-2 text-sm font-medium " \
                           "text-gray-700 shadow-sm hover:bg-gray-50"
        PRIMARY_BUTTON = "inline-flex items-center justify-center rounded-md border " \
                         "border-transparent bg-indigo-600 px-3 py-2 text-sm font-semibold " \
                         "text-white shadow-sm hover:bg-indigo-500"
        WARNING_BUTTON = "inline-flex items-center justify-center rounded-md border " \
                         "border-transparent bg-amber-500 px-3 py-2 text-sm font-semibold " \
                         "text-white shadow-sm hover:bg-amber-400"
        FIELD = "rounded-md border border-gray-300 px-3 py-2 text-sm shadow-sm " \
                "focus:border-indigo-500 focus:outline-none focus:ring-1 focus:ring-indigo-500"
        FIELD_FULL = "block w-full #{FIELD}".freeze
        CHECKBOX = "h-4 w-4 rounded border-gray-300 text-indigo-600 focus:ring-indigo-500"

        # The canonical token set. Every token a template may ask for is a key
        # here, which is what makes a typo in a template raise instead of
        # silently emitting nothing.
        DAISYUI = {
          # Layout and spacing. These are plain Tailwind utilities already, so
          # the tailwind variant inherits them unchanged — which is the whole
          # reason TAILWIND is a merge rather than a second literal map.
          page: "max-w-4xl mx-auto mb-6",
          heading: "text-2xl font-bold my-8",
          actions_bar: "my-6 flex justify-end",
          actions_bar_spaced: "my-6 flex justify-end space-x-2",
          controls: "flex flex-wrap gap-2 items-end mb-4",
          list: "space-y-3",
          load_more_wrap: "pt-2 flex justify-center",
          row_form: "space-y-2",
          checkbox_wrap: "my-4",
          form_actions: "flex gap-2 items-center",
          form: "max-w-md mx-auto",

          # Components.
          card: "card bg-base-100 shadow-sm",
          card_body: "card-body",
          card_actions: "card-actions justify-end",
          toggle: "toggle",
          toggle_sm: "toggle toggle-sm",
          btn: "btn",
          # NOTE: btn-default is not a DaisyUI class — it is inert. Kept
          # verbatim because the reference app has it and this map's job is to
          # reproduce what was measured; drop it here if it should not travel
          # into new apps.
          btn_default: "btn btn-default",
          btn_outline: "btn btn-outline",
          btn_primary: "btn btn-primary",
          btn_warning: "btn btn-warning",
          btn_ghost: "btn btn-ghost",
          btn_wide: "btn btn-outline btn-wide",
          fieldset: "fieldset border border-gray-300 p-4 mb-4",
          label: "label",
          label_text: "label-text",
          form_control: "form-control",
          input: "input",
          input_full: "input w-full",
          select: "select",
          select_full: "select w-full",
          textarea_full: "textarea w-full",
          badge_warning: "badge badge-warning",
          # The LOOK of a spinner, never its visibility — showing and hiding
          # it is an attribute-descendant rule, which no class token can
          # express, so it lives in the transport stylesheet instead. Absent
          # under --css=none, where that stylesheet hand-rolls the ring too.
          spinner: "loading loading-spinner loading-xs",
          warning_text: "text-warning",
          error_text: "text-error text-sm mt-1",
          # The full-form error summary. Plain Tailwind on purpose, so both
          # styled variants share it via the merge — an addition (2026-08-09),
          # not a transcription: the reference apps carried the scaffold-stock
          # `style="color: red"` block, which --css=none still emits.
          error_summary: "rounded-md border border-red-200 bg-red-50 p-4 mb-6",
          error_summary_title: "text-sm font-semibold text-red-800",
          error_summary_list: "mt-2 list-disc list-inside text-sm text-red-700",
          muted: "opacity-60 italic",
          muted_inline: "opacity-60",
          counts: "ml-auto text-sm opacity-70",
          # my-, not mt-: the control renders above the list as well as below,
          # and the top copy needs the gap on its other side.
          pagination_nav: "join my-2 mx-auto flex justify-center w-fit",

          # The multiselect dropdown (hibiki:rails:multiselect). One structure
          # for every variant: DaisyUI's dropdown opens on :focus-within, the
          # tailwind override hand-rolls the same rule with group-focus-within,
          # and under --css=none nothing hides the panel so the list renders
          # inline — unstyled, still functional.
          dropdown: "dropdown w-full",
          dropdown_trigger: "select w-full items-center",
          dropdown_panel: "dropdown-content bg-base-100 rounded-box z-10 mt-1 w-full p-2 shadow-md",
          option_list: "menu w-full max-h-60 flex-nowrap overflow-y-auto p-0",
          option_label: "label cursor-pointer justify-start gap-2",
          option_note: "p-2 opacity-60 italic",
          checkbox_sm: "checkbox checkbox-sm",
          filter_input: "input input-sm w-full mb-2",

          # The nested fieldset (hibiki:rails:nested): one bordered card per
          # child row, a legend on the fieldset, and the small row controls
          # (↑/↓/Remove/Add).
          fieldset_legend: "fieldset-legend px-2",
          nested_row: "border border-base-300 rounded-box p-3 mb-2 space-y-2",
          btn_ghost_sm: "btn btn-sm btn-ghost",
          btn_outline_sm: "btn btn-sm btn-outline",

          # The upload field (hibiki:rails:upload_field): the attachment row
          # in both forms, its thumbnail, the non-image filename link on the
          # row, and the pending badge on its own full-width line under the
          # controls (the row wraps, so a long filename never pushes Remove
          # off-screen). upload_row, upload_status and thumb are plain
          # utilities, so the tailwind variant inherits them.
          upload_row: "flex flex-wrap items-center gap-3",
          upload_status: "w-full",
          thumb: "rounded",
          file_link: "link link-hover",
          file_input: "file-input w-full",
          file_input_sm: "file-input file-input-sm",
          badge_info: "badge badge-info"
        }.freeze

        # DaisyUI is a plugin over Tailwind, and the merge says so literally:
        # only the component tokens are overridden, and every layout utility
        # falls through untouched.
        TAILWIND = DAISYUI.merge(
          card: "rounded-lg border border-gray-200 bg-white shadow-sm",
          card_body: "p-6 space-y-2",
          card_actions: "flex flex-wrap justify-end gap-2 pt-4",
          toggle: CHECKBOX,
          toggle_sm: CHECKBOX,
          btn: SECONDARY_BUTTON,
          btn_default: SECONDARY_BUTTON,
          btn_outline: SECONDARY_BUTTON,
          btn_primary: PRIMARY_BUTTON,
          btn_warning: WARNING_BUTTON,
          btn_ghost: SECONDARY_BUTTON,
          btn_wide: SECONDARY_BUTTON.sub("px-3", "px-12"),
          fieldset: "rounded-md border border-gray-300 p-4 mb-4",
          label: "block text-sm font-medium text-gray-700 mt-3",
          label_text: "text-sm font-medium text-gray-700",
          form_control: "flex flex-col gap-1",
          input: FIELD,
          input_full: FIELD_FULL,
          select: FIELD,
          select_full: FIELD_FULL,
          textarea_full: "#{FIELD_FULL} min-h-20",
          badge_warning: "inline-flex items-center rounded-full bg-amber-100 px-2 py-1 " \
                         "text-xs font-medium text-amber-800",
          # `inline-block` is load-bearing, not decoration: a bare span is
          # inline, where h-3/w-3 do nothing. It also collides with
          # .hbk-control-busy's `display: none` at equal specificity — the
          # transport stylesheet wins because it is UNLAYERED and Tailwind's
          # utilities are in @layer utilities, which beats them whatever the
          # link order. (Before 0.5.0 the rules were a <style> in the body and
          # won on document order instead; that is why the stylesheet's header
          # now says not to wrap it in a layer.)
          spinner: "inline-block h-3 w-3 animate-spin rounded-full border-2 " \
                   "border-current border-r-transparent align-[-0.15em]",
          warning_text: "text-amber-600",
          error_text: "text-red-600 text-sm mt-1",
          muted: "text-gray-500 italic",
          muted_inline: "text-gray-400",
          counts: "ml-auto text-sm text-gray-500",
          pagination_nav: "my-2 mx-auto flex justify-center w-fit -space-x-px rounded-md shadow-sm",
          dropdown: "group relative w-full",
          dropdown_trigger: "#{FIELD_FULL} flex cursor-pointer items-center",
          dropdown_panel: "absolute inset-x-0 z-10 mt-1 hidden rounded-md border border-gray-200 " \
                          "bg-white p-2 shadow-lg group-focus-within:block",
          option_list: "max-h-60 space-y-1 overflow-y-auto",
          option_label: "flex cursor-pointer items-center gap-2 py-1 text-sm",
          option_note: "p-2 text-gray-500 italic",
          checkbox_sm: CHECKBOX,
          filter_input: "#{FIELD_FULL} mb-2 text-sm",
          fieldset_legend: "px-2 text-sm font-medium text-gray-700",
          nested_row: "rounded-md border border-gray-200 p-3 mb-2 space-y-2",
          btn_ghost_sm: SECONDARY_BUTTON.sub("px-3 py-2", "px-2 py-1"),
          btn_outline_sm: SECONDARY_BUTTON.sub("px-3 py-2", "px-2 py-1"),
          file_link: "text-indigo-600 hover:underline",
          file_input: "block w-full text-sm text-gray-700 file:mr-3 file:rounded-md " \
                      "file:border-0 file:bg-gray-100 file:px-3 file:py-2 file:text-sm " \
                      "file:font-medium file:text-gray-700 hover:file:bg-gray-200",
          file_input_sm: "block text-xs text-gray-700 file:mr-2 file:rounded-md " \
                         "file:border-0 file:bg-gray-100 file:px-2 file:py-1 file:text-xs " \
                         "file:font-medium file:text-gray-700 hover:file:bg-gray-200",
          badge_info: "inline-flex items-center rounded-full bg-sky-100 px-2 py-1 " \
                      "text-xs font-medium text-sky-800"
        ).freeze

        # Every lookup misses, so every class argument is omitted entirely.
        NONE = {}.freeze

        VARIANTS = { daisyui: DAISYUI, tailwind: TAILWIND, none: NONE }.freeze
        NAMES = VARIANTS.keys.map(&:to_s).freeze

        class << self
          # Validated against DAISYUI rather than the active variant, so a
          # mistyped token raises under --css=none too — where it would
          # otherwise look exactly like a token that is meant to be absent.
          def token(variant, name)
            raise ArgumentError, "unknown css token #{name.inspect}" unless DAISYUI.key?(name)

            VARIANTS.fetch(variant.to_sym)[name]
          end

          # A grep, not a dependency lookup: DaisyUI is a CSS-only plugin under
          # Tailwind 4, so it appears in package.json and in the entry
          # stylesheet but never in the Gemfile.
          #
          # cssbundling-rails is deliberately NOT a signal — it bundles
          # Bootstrap and Sass just as happily, and guessing tailwind from it
          # would restyle an app that has no Tailwind at all.
          def detect(root)
            return :daisyui if daisyui?(root)
            return :tailwind if tailwind?(root)

            :none
          end

          private

          def daisyui?(root)
            contains?(root, "package.json", %("daisyui")) ||
              Dir[File.join(root, "app/assets/stylesheets/*.css")]
                .any? { File.read(it).include?(%(@plugin "daisyui")) }
          end

          def tailwind?(root)
            contains?(root, "package.json", %("tailwindcss")) ||
              contains?(root, "Gemfile", "tailwindcss-rails")
          end

          def contains?(root, path, fragment)
            full = File.join(root, path)
            File.exist?(full) && File.read(full).include?(fragment)
          end
        end
      end
    end
  end
end
