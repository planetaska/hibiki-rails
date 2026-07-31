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
          restart_notice
          rebuild_css_notice
          association_notices
          field_order_notice
          live_errors_notice
          skipped_notice
          wiring_hint
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
            next if schema.introspected?

            say_status :assoc, "#{column.association_class_name} needs `has_many :#{controller_file_name}` " \
                               "with a dependent: option, or destroying one raises InvalidForeignKey", :blue
          end
        end

        # Field order follows whatever columns_hash reports, which for an app
        # built from schema.rb is ALPHABETICAL — so a generated form can read
        # "Available, Intro, Title" where a person would have led with the
        # title. There is no authored order to recover from a schema, so the
        # lever is the argument list.
        def field_order_notice
          return unless schema.introspected? && schema.columns.size > 2

          say_status :order, "fields follow the schema's column order — pass them explicitly to " \
                             "choose it: bin/rails g hibiki:rails:scaffold_controller " \
                             "#{name} #{schema.columns.first(2).map { field_syntax(it) }.join(' ')} ...", :blue
        end

        # A belongs_to is declared by its ASSOCIATION name, not its foreign key:
        # `author:references`, never `author_id:references`.
        def field_syntax(column)
          column.belongs_to? ? "#{column.association_name}:references" : "#{column.name}:#{column.type}"
        end

        def live_errors_notice
          return if schema.live_errors.any? && schema.introspected?

          reason = if schema.introspected?
                     "#{class_name} declares no validators readable before a round trip"
                   else
                     "the migration has not run, so this command had no schema and no validators to read"
                   end
          # Deliberately NOT "add validators and it lights up": the clauses are
          # generated ONCE, into a file the generator then stops owning. A
          # commit-time failure still mirrors the model's own errors into the
          # same per-field slots with no change at all — it is the check BEFORE
          # the round trip that has to be re-derived.
          say_status :form, "#{form_path}'s live_errors is thin — #{reason}. Add validators to the model, " \
                            "then re-run `bin/rails g hibiki:rails:scaffold_controller #{name}` to derive " \
                            "the clauses from them (or write them there by hand)", :blue
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
