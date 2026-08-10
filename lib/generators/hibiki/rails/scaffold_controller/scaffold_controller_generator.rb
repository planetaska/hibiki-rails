# frozen_string_literal: true

require "rails/generators"
require "rails/generators/resource_helpers"
require_relative "../generator_helpers"
require_relative "../scaffold_helpers"
require_relative "../scaffold_view_helpers"
require_relative "../scaffold_model_injection"
require_relative "../scaffold_parent_injection"
require_relative "../scaffold_parent_notices"
require_relative "../scaffold_phlex_helpers"
require_relative "../scaffold_post_install"
require_relative "../scaffold_shared_views"
require_relative "../scaffold_transport_stylesheet"
require_relative "../scaffold_schema"
require_relative "../css_variant"

module Hibiki
  module Rails
    module Generators
      # A reactive CRUD resource for a model that already exists: the graph
      # (a collection channel and a per-record one), a shared query object, a
      # ReactiveForm, the views, and a scaffold-shaped controller that still
      # serves the first paint and the non-JS path.
      #
      # Everything is derived from the model's schema — column names, column
      # types, belongs_to reflections — or from the same `NAME field:type`
      # argument list Rails' own scaffold takes. Nothing here knows what a
      # "book" is.
      class ScaffoldControllerGenerator < ::Rails::Generators::NamedBase
        include ::Rails::Generators::ResourceHelpers
        include GeneratorHelpers
        include ScaffoldHelpers
        include ScaffoldViewHelpers
        include ScaffoldPhlexHelpers
        include ScaffoldModelInjection
        include ScaffoldParentInjection
        include ScaffoldParentNotices
        include ScaffoldPostInstall
        include ScaffoldSharedViews
        include ScaffoldTransportStylesheet

        TEMPLATE_ROOT = File.expand_path("templates", __dir__)

        source_root TEMPLATE_ROOT

        desc "Generates a reactive CRUD resource for an existing model: channels, " \
             "query object, ReactiveForm, views and controller."

        argument :attributes, type: :array, default: [], banner: "field:type field:type"

        class_option :css, type: :string, enum: CssVariant::NAMES,
                           desc: "Markup variant for every generated view (default: detect)"
        class_option :infinite_scroll, type: :boolean, default: false,
                                       desc: "Grow the window on scroll instead of numbering pages"
        class_option :skip_pagination, type: :boolean, default: false,
                                       desc: "No windowing at all — skips both pagination modes"
        class_option :skip_search, type: :boolean, default: false,
                                   desc: "Omit the search box and the LIKE terms behind it"
        class_option :page_size, type: :numeric, default: 20,
                                 desc: "Rows per page"
        class_option :skip_routes, type: :boolean,
                                   desc: "Don't add routes to config/routes.rb"
        class_option :phlex, type: :boolean, default: false,
                             desc: "Emit Phlex components under app/views instead of ERB templates"

        # Deliberately NO check_class_collision on the controller. Rails' own
        # scaffold_controller assumes a brand-new resource; this one's primary
        # use is an OVERLAY onto an already-scaffolded model, where the
        # controller existing is the normal case rather than an error. Thor's
        # per-file conflict prompt is the right granularity for that.

        # First, so a --phlex app missing its wiring reads that at the TOP of
        # the output rather than under forty created-file lines. It only warns,
        # so the files are written either way — see ScaffoldPhlexHelpers.
        def check_phlex_wiring
          warn_without_phlex_rails
        end

        # Resolving the schema first means a missing model or an unmigrated
        # table aborts before anything is written, rather than half-way through.
        def resolve_schema
          schema
          # Captured BEFORE anything is written, so post_install can tell which
          # app/* directories are new — Rails computes autoload paths from that
          # glob at boot, and a new one needs a restart.
          @new_app_dirs = %w[app/forms app/channels app/models app/views].reject { exists?(it) }
        end

        # One file per app, not per resource, and the only thing this generator
        # writes outside app/{channels,models,forms,views,controllers}. It
        # carries no model knowledge at all — the rules key on the client's
        # attributes — so a second resource finds it already there.
        def create_stylesheet
          create_transport_stylesheet
        end

        def create_channels
          template "channel.rb.tt", collection_channel_path
          template "member_channel.rb.tt", member_channel_path
        end

        def create_models
          template "query.rb.tt", query_path
        end

        def create_form
          template "form.rb.tt", form_path
        end

        def create_controller
          template "controller.rb.tt", scaffold_controller_path
        end

        def create_views
          if phlex?
            create_phlex_views
          else
            %w[index show new edit _form _list _controls].each do |view|
              template "views/#{view}.html.erb.tt", view_path("#{view}.html.erb")
            end

            template "views/_row.html.erb.tt", view_path("_#{row_partial}.html.erb")
            template "views/_row_form.html.erb.tt", view_path("_#{row_form_partial}.html.erb")
          end

          # The page control and the field-error line, once per app — see
          # ScaffoldSharedViews.
          create_shared_views
        end

        # The model being scaffolded — one of two files this generator modifies
        # that the app already owned. It gets the after_commit ping, which is
        # what makes another tab, another user, the plain controller and a
        # console write all reach an open list.
        #
        # The alternative — printing it and hoping — fails SILENTLY: everything
        # works in one tab, and cross-tab plus out-of-band writes simply never
        # arrive.
        def inject_model_support
          return manual_wiring(model_path, model_support) unless exists?(model_path)
          return if wired?(model_path, ping_marker)

          inject_into_model model_path, class_name, model_support
          announce_model_change
        end

        # The other one: the model a belongs_to points AT, which Rails' own
        # scaffold never touches. It owes this resource two things it cannot
        # write for itself — the has_many half of the association, and a ping,
        # because a row prints the parent's label rather than its id. Both are
        # derived from the reflection; see ScaffoldParentInjection.
        def inject_parent_support
          inject_parent_models
        end

        # The `route` action directly rather than `hook_for :resource_route`.
        # The hook resolves through Rails::Generators.find_by_namespace with
        # OUR base_name ("hibiki"), which is a resolution risk for a one-line
        # action — and calling it here also keeps `hibiki:rails:scaffold` from
        # having to reason about whether Thor de-duplicated the invocation.
        # Guarded, so re-running an overlay does not stack duplicate routes.
        def add_route
          return if options[:skip_routes] || route_declared?

          route "resources :#{plural_name}", namespace: regular_class_path
        end

        def post_install
          post_install_notices
        end

        private

        # No underscore, no .html.erb, and no _row/_row_form rename: all three
        # are Rails PARTIAL conventions, and a Phlex component is reached by
        # constant. Dropping the rename also drops a step — the file is
        # row.rb because Zeitwerk wants basename.camelize, and calling it
        # book.rb would put Views::Books::Book one reformat away from shadowing
        # the model inside its own namespace.
        #
        # Private, because a public method on a Thor generator is a command.
        def create_phlex_views
          %w[index show new edit form list row row_form controls].each do |view|
            template "views/#{view}.rb.tt", view_path("#{view}.rb")
          end
        end

        # Ordered so an app's own lib/templates/... override wins first, then
        # the view layer, then the per-variant fork, then the one shared
        # template set. Only the page control has a per-variant file — a
        # tag-name change under `none` and a shared-local extraction under
        # `tailwind`, neither of which a class-token map can express — so
        # everything else falls through to shared/.
        #
        # The two layers' templates never collide (list.rb.tt vs
        # _list.html.erb.tt), so the phlex roots could have lived beside the
        # ERB ones. They are a subtree instead because `ls` is where this
        # phase's permanent cost should be visible: every view change is now
        # two templates, forever.
        def source_paths
          @source_paths ||= [*self.class.source_paths_for_search,
                             *phlex_source_paths,
                             File.join(TEMPLATE_ROOT, css_variant.to_s),
                             File.join(TEMPLATE_ROOT, "shared")]
        end

        def phlex_source_paths
          return [] unless phlex?

          [File.join(TEMPLATE_ROOT, "phlex", css_variant.to_s),
           File.join(TEMPLATE_ROOT, "phlex", "shared")]
        end

        # Explicit attributes always win, matching Rails' own precedence; the
        # schema decides the column list only when the argument list is empty.
        # That order also happens to be the only workable one, because
        # `hibiki:rails:scaffold` invokes this generator BEFORE its migration
        # has run.
        #
        # An argument list does NOT mean the model is ignored, though: when
        # there is one to read, the arguments choose the order and the model
        # still answers everything else. #introspectable_model is what makes
        # that conditional, and it is nil on exactly the path where the
        # arguments are the only source there is.
        def schema
          @schema ||= if attributes.any?
                        ScaffoldSchema.from_attributes(attributes, model: introspectable_model)
                      else
                        ScaffoldSchema.from_model(model_class)
                      end
        end

        # The model whose facts an argument list can borrow, or nil when there
        # is nothing to borrow yet.
        #
        # Deliberately NOT #model_class: a missing model is an ERROR there,
        # because an empty argument list leaves the generator with no source at
        # all. Here it is the ordinary case — `hibiki:rails:scaffold` writes the
        # model file and then invokes this generator with the migration still
        # unrun, so the constant may load and the table will not exist.
        def introspectable_model
          return @introspectable_model if defined?(@introspectable_model)

          klass = class_name.safe_constantize
          # Parenthesised: `@ivar = x if cond` leaves the ivar UNDEFINED when
          # the condition is false, which would defeat the guard above and
          # re-query the database on every call.
          @introspectable_model = (klass if klass.respond_to?(:table_exists?) && klass.table_exists?)
        rescue StandardError
          # No connection, no database, an abstract class: all "nothing to read
          # from", none of them worth failing a generate over.
          @introspectable_model = nil
        end

        # Aborts rather than falling back to an empty attribute list. A silent
        # fallback would emit an empty allowlist, an empty row projection and a
        # fieldless form — all syntactically valid, all useless, and it would
        # look exactly like the generator worked.
        def model_class
          klass = class_name.safe_constantize
          raise ::Rails::Generators::Error, missing_model_message unless klass

          # Touch the schema here so an unmigrated table fails with our message
          # rather than somewhere inside a template.
          klass.tap(&:columns_hash)
        rescue ::Rails::Generators::Error
          raise
        rescue StandardError
          raise ::Rails::Generators::Error, missing_table_message
        end

        def missing_model_message
          "No model #{class_name}. Either create one —\n    " \
            "bin/rails g hibiki:rails:scaffold #{name} title:string\n  " \
            "— or pass the fields explicitly:\n    " \
            "bin/rails g hibiki:rails:scaffold_controller #{name} title:string"
        end

        def missing_table_message
          "#{class_name} has no table yet. Run bin/rails db:migrate first, " \
            "or pass the fields explicitly:\n    " \
            "bin/rails g hibiki:rails:scaffold_controller #{name} title:string"
        end

        def css_variant
          @css_variant ||= (options[:css] || CssVariant.detect(destination_root)).to_sym
        end

        def css(token) = CssVariant.token(css_variant, token)
        def css? = css_variant != :none

        # nil means "no window": .limit(nil) and .offset(nil) are both relation
        # no-ops, so one constant replaces template conditionals across five
        # files.
        def page_size_literal = options[:skip_pagination] ? "nil" : Integer(options[:page_size]).to_s

        def infinite? = options[:infinite_scroll]
        def searchable? = schema.searchable? && !options[:skip_search]

        # The view layer. It reaches the templates and nothing else: the graph,
        # the query object, the form, the actions and the whole data-hibiki
        # protocol are the same either way.
        def phlex? = options[:phlex]
      end
    end
  end
end
