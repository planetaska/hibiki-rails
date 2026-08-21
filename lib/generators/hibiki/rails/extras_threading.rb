# frozen_string_literal: true

module Hibiki
  module Rails
    module Generators
      # Threading the extras: hash through a pre-0.7.0 scaffold's partial
      # chain. Scaffolds since 0.7.0 emit it themselves (list -> row ->
      # row_form, untouched), so on those this is a no-op probe; older
      # output gets the header/keyword plus the two render calls retrofitted,
      # anchored on text every scaffold emitted verbatim.
      #
      # Shared by every add-on generator that rides extras:
      # (hibiki:rails:multiselect, hibiki:rails:upload_field). Depends on the
      # generator for view_path/row_partial/row_form_partial/phlex?.
      module ExtrasThreading
        private

        def thread_extras_through_partials
          return if wired?(extras_probe_path, "extras")

          say_status :compat, "pre-0.7 scaffold — threading extras: through the partials", :yellow
          phlex? ? thread_extras_phlex : thread_extras_erb
          return if wired?(extras_probe_path, "extras")

          say_status :warn, "could not thread extras: automatically. Pass an extras: {} local " \
                            "from the list partial down to #{row_form_partial} yourself.", :yellow
        end

        def extras_probe_path = phlex? ? view_path("row_form.rb") : view_path("_#{row_form_partial}.html.erb")

        def thread_extras_erb
          [view_path("_list.html.erb"), view_path("_#{row_partial}.html.erb"),
           view_path("_#{row_form_partial}.html.erb")].each do |path|
            # /m: the row form's locals header wraps onto a second line.
            gsub_file path, /^(<%# locals: \(.*?)\) -%>/m, '\1, extras: {}) -%>', verbose: false
          end
          # `form: form` appears exactly once per file, inside the one render
          # call that must pass extras on.
          gsub_file view_path("_list.html.erb"), "form: form", "form: form, extras: extras"
          gsub_file view_path("_#{row_partial}.html.erb"), "form: form", "form: form, extras: extras"
        end

        def thread_extras_phlex
          %w[list.rb row.rb row_form.rb].each do |basename|
            path = view_path(basename)
            gsub_file path, /(def initialize\([^)]*)\)/, '\1, extras: {})', verbose: false
            gsub_file path, /^(\s*)@form = form$/, "\\1@form = form\n\\1@extras = extras", verbose: false
          end
          gsub_file view_path("list.rb"), "form: @form", "form: @form, extras: @extras"
          gsub_file view_path("row.rb"), "form: @form", "form: @form, extras: @extras"
        end
      end
    end
  end
end
