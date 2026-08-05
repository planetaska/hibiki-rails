# frozen_string_literal: true

module Hibiki
  module Rails
    module Generators
      # What the scaffold generators tell you once the files are written.
      #
      # Every notice here exists because the thing it warns about fails
      # SILENTLY: a new app/* directory is not autoloadable until a restart,
      # Tailwind purges classes it cannot see, an association's display label is
      # a guess, and a form with no validators to read shows no per-field
      # feedback. None of these raises, and none is visible in the file list.
      module ScaffoldPostInstall
        private

        def post_install_notices
          app_notices
          schema_notices
          wiring_hint
        end

        # What this app needs doing before the output works: a restart, a
        # stylesheet, a leftover file. None of them is about the resource.
        def app_notices
          restart_notice
          # These two live with the code that chose their branch, like
          # parent_notices — the outcomes are those modules' vocabulary.
          stylesheet_notice
          stale_erb_views_notice
          rebuild_css_notice
        end

        # What the generator could and could not read, and what it guessed.
        def schema_notices
          association_notices
          field_order_notice
          unmatched_fields_notice
          live_errors_notice
          uniqueness_notice
          skipped_notice
        end

        def restart_notice
          return if @new_app_dirs.blank?

          say_status :restart, "#{@new_app_dirs.join(', ')} #{@new_app_dirs.one? ? 'is' : 'are'} new — " \
                               "Rails computes autoload paths from the app/* glob at BOOT, so restart " \
                               "the server or the new constants raise NameError", :yellow
        end

        def rebuild_css_notice
          return unless css?

          command = exists?("package.json") ? "bun run build:css" : "bin/rails tailwindcss:build"
          say_status :css, "these views introduce classes your stylesheet has never seen; " \
                           "Tailwind purges what it cannot find, so rebuild: #{command}", :yellow
        end

        def association_notices
          schema.belongs_tos.each do |column|
            say_status :assoc, "using #{column.association_class_name}##{column.label_column} as the " \
                               "display label — edit #{row_path} and the form views if that's wrong", :blue
          end

          # The parent's own notices live with the code that decided them, in
          # ScaffoldParentInjection — the outcomes are that module's vocabulary.
          parent_notices
        end

        # Field order follows whatever columns_hash reports, which for an app
        # built from schema.rb is ALPHABETICAL — so a generated form can read
        # "Available, Intro, Title" where a person would have led with the
        # title. There is no authored order to recover from a schema, so the
        # lever is the argument list.
        #
        # `schema_ordered?`, not `introspected?`: an argument list against a
        # migrated model is introspected TOO, and there the user has already
        # chosen the order this notice exists to offer.
        def field_order_notice
          return unless schema.schema_ordered? && schema.columns.size > 2

          say_status :order, "fields follow the schema's column order — pass them explicitly to " \
                             "choose it: bin/rails g hibiki:rails:scaffold_controller " \
                             "#{name} #{schema.columns.first(2).map { field_syntax(it) }.join(' ')} ... " \
                             "(the validators still come from the model either way; " \
                             "the generated views are yours to reorder by hand too)", :blue
        end

        # An explicit field the model has no column for. Kept rather than
        # dropped — it may be a column whose migration is still to come — but
        # it cannot carry a validator, a bound or an association label, and if
        # it is a typo the form will not discover that until #commit.
        def unmatched_fields_notice
          return if schema.unmatched.empty?

          say_status :fields, "#{class_name} has no column for " \
                              "#{schema.unmatched.to_sentence} — generated from the argument list alone, " \
                              "so nothing about #{schema.unmatched.one? ? 'it' : 'them'} was read from the " \
                              "model. Check the spelling, or migrate first and re-run", :yellow
        end

        # A belongs_to is declared by its ASSOCIATION name, not its foreign key:
        # `author:references`, never `author_id:references`.
        def field_syntax(column)
          column.belongs_to? ? "#{column.association_name}:references" : "#{column.name}:#{column.type}"
        end

        def live_errors_notice
          return if schema.live_errors.any? && schema.introspected?

          # Deliberately NOT "add validators and it lights up": the clauses are
          # generated ONCE, into a file the generator then stops owning. A
          # commit-time failure still mirrors the model's own errors into the
          # same per-field slots with no change at all — it is the check BEFORE
          # the round trip that has to be re-derived.
          say_status :form, "#{form_path}'s live_errors is thin — #{live_errors_reason}. Add validators to " \
                            "the model, then re-run `#{rerun_command}` to derive the clauses from them " \
                            "(or write them there by hand)", :blue
        end

        # Three reachable situations, and two of them used to share one
        # sentence that was true of only one. "The migration has not run" is
        # right for `hibiki:rails:scaffold`, which really does generate ahead of
        # its own schema — and wrong for both a name with no model behind it at
        # all and, since the order/facts merge, an explicit field list against a
        # migrated app, where the validators WERE read and the model simply
        # declares none this generator can use.
        def live_errors_reason
          return "#{class_name} declares no validators readable before a round trip" if schema.introspected?
          return "there is no #{class_name} yet, so this command had no validators to read" unless model_present?

          "the migration has not run, so this command had no schema and no validators to read"
        end

        # The FILE, not the constant. `hibiki:rails:scaffold` writes the model
        # and then invokes this generator in the same process, where the new
        # constant is not autoloadable yet — so asking Ruby would answer "there
        # is no Widget" about a file the user just watched scroll past, and
        # send them to write a model they already have.
        def model_present? = exists?(model_path) || class_name.safe_constantize

        # Re-running has to preserve the field list, or the advice costs the
        # user the order they chose — which was §5.16 in the other direction.
        def rerun_command
          fields = attributes.map { to_argv(it) }.join(" ")

          "bin/rails g hibiki:rails:scaffold_controller #{name}#{" #{fields}" unless fields.empty?}"
        end

        # §5.15. A unique index the model says nothing about: #commit can only
        # mirror what the model checks, so the constraint fires first and
        # raises RecordNotUnique instead of returning false. On the graph
        # thread that is a dev-log line, and since the post-batch ack clears
        # the busy indicator from an `ensure`, the user sees a round trip that
        # completes cleanly and saves nothing.
        #
        # Silent until someone types a duplicate, which is what every notice
        # here has in common.
        def uniqueness_notice
          schema.unmirrored_uniqueness.each do |columns|
            say_status :unique, "#{indexed_columns(columns)} #{columns.one? ? 'has' : 'have'} a unique " \
                                "index and #{class_name} has no matching validator, so a duplicate raises " \
                                "RecordNotUnique instead of showing a field error — add " \
                                "`#{uniqueness_validator(columns)}`", :yellow
          end
        end

        def indexed_columns(columns)
          columns.one? ? "#{plural_table_name}.#{columns.first}" : "#{plural_table_name} (#{columns.join(', ')})"
        end

        # A composite index is mirrored by scoping the validator to the rest of
        # its columns; AR attaches that to the first one.
        def uniqueness_validator(columns)
          first, *rest = columns
          scope = rest.one? ? ":#{rest.first}" : "%i[#{rest.join(' ')}]"

          rest.empty? ? "validates :#{first}, uniqueness: true" : "validates :#{first}, uniqueness: { scope: #{scope} }"
        end

        def skipped_notice
          return if schema.skipped.empty?

          schema.skipped.each do |name, reason|
            say_status :skip, "#{name} — #{reason}", :yellow
          end
        end
      end
    end
  end
end
