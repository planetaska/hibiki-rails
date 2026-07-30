# frozen_string_literal: true

module Hibiki
  module Rails
    module Generators
      # Naming, destinations and argument round-tripping for the scaffold
      # generators.
      #
      # Everything resource-shaped lives here rather than in GeneratorHelpers,
      # which the four existing shape generators share and which knows only one
      # grain. Nothing in this module is public: a public method on a Thor
      # generator is a command, and `bin/rails g` would try to run it.
      module ScaffoldHelpers
        private

        # ---- the two grains --------------------------------------------------
        #
        # A scaffold names things at TWO grains and they are not
        # interchangeable: the collection island (BooksChannel, streaming
        # "admin:books") and the single record (BookChannel, "admin:book").
        #
        # GeneratorHelpers#stream_name is the MEMBER grain — right for the show
        # page, silently wrong for the index — so both are named explicitly here
        # and nothing calls the inherited one. A collection channel that
        # streamed from the singular name would subscribe successfully and
        # never receive a broadcast, which is the worst shape a bug can take.

        def collection_parts = controller_class_path + [controller_file_name]
        def member_parts = class_path + [file_name]

        def collection_stream_name = collection_parts.join(":")
        def member_stream_name = member_parts.join(":")

        # ActionCable derives channel_name by stripping "Channel" and turning
        # "::" into ":", so these two agree with the class names below by
        # construction rather than by coincidence.
        def collection_channel_class_name = "#{controller_class_name}Channel"
        def member_channel_class_name = "#{class_name}Channel"

        # The streamable the model's after_commit pings. Global to the
        # collection because the generic rule is "scope the streamable to
        # whatever scopes the query", and a generated query is unscoped.
        def changed_streamable = "#{collection_stream_name}:changed"

        # ---- emitted class names ---------------------------------------------

        def query_class_name = "#{class_name}Query"
        def row_class_name = "#{class_name}Row"
        def form_class_name = "#{class_name}Form"
        def scaffold_controller_class_name = "#{controller_class_name}Controller"

        # ---- destinations ----------------------------------------------------
        #
        # The query object and the row projection go in app/models, NOT a new
        # app/queries: Rails computes autoload paths from the app/* glob at
        # boot, so a new top-level directory is not autoloadable until a server
        # restart. app/forms already costs one restart; two would be gratuitous.

        def view_dir = File.join("app/views", controller_file_path)
        def collection_channel_path = File.join("app/channels", "#{controller_file_path}_channel.rb")
        def member_channel_path = File.join("app/channels", *class_path, "#{file_name}_channel.rb")
        def model_path = File.join("app/models", *class_path, "#{file_name}.rb")
        def query_path = File.join("app/models", *class_path, "#{file_name}_query.rb")
        def row_path = File.join("app/models", *class_path, "#{file_name}_row.rb")
        def form_path = File.join("app/forms", *class_path, "#{file_name}_form.rb")

        def scaffold_controller_path
          File.join("app/controllers", "#{controller_file_path}_controller.rb")
        end

        def view_path(basename) = File.join(view_dir, basename)

        # ---- dom ids and reactive value names --------------------------------
        #
        # Namespaced so several generated islands can share a page. Every value
        # name has to satisfy Helpers::VALUE_NAME (/\A[a-z][a-z0-9_-]*\z/i),
        # which plural_table_name does by construction — it is underscore-joined.

        def list_dom_id = plural_table_name
        def row_dom_id_prefix = singular_table_name
        def pagination_dom_id = "#{plural_table_name}_pagination"
        def empty_dom_id = "#{plural_table_name}_empty"
        def load_more_dom_id = "#{plural_table_name}_load_more"
        def value_name(suffix) = "#{plural_table_name}_#{suffix}"

        # ---- partial names ---------------------------------------------------

        def row_partial = singular_name
        def row_form_partial = "#{singular_name}_form"

        # ---- emitting Ruby ---------------------------------------------------

        def symbol_array(names) = "%i[#{names.join(' ')}]"

        # Wrap a comma-separated list so generated code is readable without a
        # formatter pass. A resource with twenty columns would otherwise emit a
        # 300-character Data.define.
        def wrapped_list(items, indent: 2, width: 88)
          prefix = " " * indent

          items.each_with_object([]) do |item, lines|
            if lines.empty? || "#{lines.last}, #{item}".length > width
              lines[-1] += "," unless lines.empty?
              lines << (prefix + item)
            else
              lines[-1] = "#{lines.last}, #{item}"
            end
          end.join("\n")
        end

        def wrapped_symbols(names, indent: 2, width: 78)
          wrapped_list(names.map { ":#{it}" }, indent: indent, width: width)
        end

        # The sort control's option pairs, as Ruby source. The view offers and
        # the query object's SORTABLE decides — duplicated on purpose, because
        # a view reaching into the allowlist would make a security boundary
        # look like presentation.
        def sort_option_pairs(indent:)
          wrapped_list(sortable_pairs, indent: indent)
        end

        def sortable_pairs
          schema.sortable.map { %([#{it.to_s.humanize.inspect}, #{it.to_s.inspect}]) }
        end

        # ---- argument round-tripping ----------------------------------------

        # GeneratedAttribute#to_s does NOT round-trip. `title:string!` comes
        # back as "title:string{null}", because print_attribute_options falls
        # through to joining the option KEYS — and .parse then rejects that with
        # "unknown type 'string{null}'". So the scaffold generator rebuilds the
        # argv form itself before handing attributes to the controller
        # generator. Verified against railties 8.1.3; regression spec in
        # spec/generators/scaffold_generator_spec.rb.
        def to_argv(attr)
          bang = attr.attr_options[:null] == false ? "!" : ""
          index = if attr.has_uniq_index? then ":uniq"
                  elsif attr.has_index? then ":index"
                  else ""
                  end

          "#{attr.name}:#{attr.type}#{argv_options(attr)}#{bang}#{index}"
        end

        # The inverse of parse_type_and_options: {small} for a text size,
        # {30} for a limit, {10,2} for a decimal, and {polymorphic} for the
        # flag-style reference options.
        def argv_options(attr)
          options = attr.attr_options
          return "{#{options[:size]}}" if options[:size]
          return "{#{options[:limit]}}" if options[:limit]
          return "{#{options[:precision]},#{options[:scale]}}" if options[:precision] && options[:scale]

          flags = options.except(:size, :limit, :precision, :scale, :null, :index).keys
          flags.empty? ? "" : "{#{flags.join(',')}}"
        end
      end
    end
  end
end
