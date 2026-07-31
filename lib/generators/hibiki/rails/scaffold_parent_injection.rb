# frozen_string_literal: true

module Hibiki
  module Rails
    module Generators
      # What the scaffold writes into the model a belongs_to points AT — the
      # second file the app already owned, and the one Rails' own scaffold
      # never touches at all.
      #
      # Two things, and each fixes a failure the child's own injection cannot
      # reach. The has_many, because `author:references` writes only the
      # belongs_to half: without it the first `author.destroy!` raises
      # InvalidForeignKey, from a destroy button THIS generator emitted. And
      # the ping, because a row prints the PARENT's label rather than its id —
      # so a rename leaves every open index printing the old one until
      # something happens to write a child.
      #
      # Both names come from a reflection rather than from this generator's own
      # argument, which is why they live here and not in ScaffoldModelInjection.
      # Reports its outcomes rather than printing them: ScaffoldParentNotices
      # turns them into the lines the user reads.
      module ScaffoldParentInjection
        private

        def inject_parent_models
          # Grouped by FILE, not by column. Injection is already duplicate-safe
          # without this — Thor writes synchronously and wired? re-reads — but
          # two belongs_tos landing on one model (author + editor, both
          # Authors) would otherwise be reported as "Author already declares
          # has_many :books", a sentence this generator wrote itself one column
          # earlier.
          @parent_reports = schema.belongs_tos
                                  .group_by { parent_model_path(it) }
                                  .map { |path, columns| wire_parent(path, columns) }
        end

        def wire_parent(path, columns)
          # `Category belongs_to :parent, class_name: "Category"`: the parent
          # file IS the child file. The ping is already there — the child's own
          # after_commit fires on exactly the writes this one would have — and
          # `parent` has no plural a generator may invent. Detected by path
          # rather than by the marker, which would also match, so the notice
          # can tell the two situations apart.
          return parent_report(path, columns, :self_referential) if path == model_path

          # Two belongs_tos, one parent: `has_many :books` cannot serve both.
          # Rails needs `has_many :edited_books`, and only a person knows that
          # word.
          collides = columns.size > 1

          # Each piece decided independently — a hand-written has_many and a
          # hand-written ping are separate decisions, and finding one must
          # neither cancel the other nor go unmentioned. `kept` is what the file
          # already had, and it is reported even when something else was
          # written: a user who chose `dependent: :restrict_with_error` should
          # be told the generator looked and respected it.
          kept = []
          kept << :has_many if wired?(path, inverse_marker)
          kept << :ping if wired?(path, ping_marker)

          pieces = %i[has_many ping] - kept
          pieces -= [:has_many] if collides
          return parent_report(path, columns, :already_wired, kept: kept, collides: collides) if pieces.empty?

          write_parent(path, columns, pieces, kept, collides)
        end

        def write_parent(path, columns, pieces, kept, collides)
          snippet = parent_support(pieces, columns.first)

          # wired? is false for a missing file, so `kept` is empty there and the
          # snippet is always the whole of what is owed rather than half of it.
          unless exists?(path)
            manual_wiring(path, snippet)
            return parent_report(path, columns, :no_file, pieces: pieces, collides: collides)
          end

          inject_into_model(path, columns.first.association_class_name, snippet)
          parent_report(path, columns, :injected, pieces: pieces, kept: kept, collides: collides)
        end

        def parent_report(path, columns, outcome, pieces: [], kept: [], collides: false)
          { path: path, columns: columns, outcome: outcome, pieces: pieces, kept: kept, collides: collides }
        end

        # ---- naming ----------------------------------------------------------

        # app/models/admin/author.rb from "Admin::Author" — the shape model_path
        # builds, with the parts coming from the reflection instead of from
        # this generator's argument. Polymorphic belongs_tos never reach here:
        # both schema builders refuse them, so every column in belongs_tos
        # names exactly one class and one file.
        def parent_model_path(column)
          File.join("app/models", "#{column.association_class_name.underscore}.rb")
        end

        # Anchored at the declaration rather than matched as a substring:
        # `has_many :books_on_loan` CONTAINS "has_many :books", and reading
        # that as "already wired" would leave the parent with no dependent:
        # option while the generator reported success.
        def inverse_marker = /^\s*has_many\s+:#{plural_name}\b/

        # ---- the injected Ruby -----------------------------------------------

        # Trailing newline for the same reason model_support has one: this
        # lands at the top of a model the app wrote and is still using.
        def parent_support(pieces, column)
          parts = []
          parts << parent_has_many(column) if pieces.include?(:has_many)
          parts << parent_ping_callback if pieces.include?(:ping)
          "#{parts.join("\n").indent(2)}\n"
        end

        # Interpolations sit at the END of a line wherever possible: this prose
        # is wrapped once, here, but lands in a file whose names vary in length,
        # and a name spliced mid-sentence makes every line after it ragged.
        def parent_has_many(column)
          <<~RUBY
            # The other half of the belongs_to on #{class_name}.
            # Rails' scaffold writes only the child's side, so without this the
            # first destroy! here raises InvalidForeignKey — from the destroy
            # action that scaffold emitted.
            #
            # dependent: follows the ASSOCIATION's requiredness, not the foreign
            # key's null constraint. With belongs_to_required_by_default a
            # nullable column routinely backs a required belongs_to, and
            # :nullify there would leave behind rows that fail their own
            # validations.
            #{inverse_line(column)}
          RUBY
        end

        def parent_ping_callback
          <<~RUBY
            # A row carries the LABEL this record contributes, not just its id,
            # so renaming one here changes what every open index prints — and
            # nothing else would say so. after_commit, not after_save, so
            # subscribers only re-read once the data is visible; no payload,
            # because the message says the table moved, not what changed.
            #
            # The COLLECTION grain only. Reaching each record's own streamable
            # would mean loading every child inside this callback, unbounded, on
            # every write — so an open show page keeps the old label until it is
            # reloaded. That is the documented edge of this ping, not an
            # oversight.
            after_commit do
              ActionCable.server.broadcast(#{collection_channel_class_name}::CHANGED, {})
            end
          RUBY
        end

        def inverse_line(column)
          options = [*class_name_option, *key_options(column), "dependent: #{dependent_option(column)}"]

          "has_many :#{plural_name}, #{options.join(', ')}"
        end

        # `has_many :books` declared on a top-level Author resolves ::Book,
        # never Admin::Book — compute_type walks the DECLARING class's nesting,
        # and the parent's namespace is not ours to assume. A plain equality
        # rather than a namespace sniff, so irregular inflections
        # (people/Person) come out right too.
        def class_name_option
          "class_name: #{class_name.inspect}" unless plural_name.classify == class_name
        end

        # Rails derives a has_many's foreign key from the PARENT's name, which
        # is wrong the moment the belongs_to was renamed. Passing :foreign_key
        # also switches OFF automatic inverse detection outright
        # (can_find_inverse_of_automatically? refuses it), so the inverse has to
        # be named in the same breath or every parent<->child hop loads a second
        # copy of the record it just came from.
        def key_options(column)
          return [] if column.name.to_s == column.association_class_name.foreign_key

          ["foreign_key: :#{column.name}", "inverse_of: :#{column.association_name}"]
        end

        def dependent_option(column) = column.required? ? ":destroy" : ":nullify"

        def parent_variable(column) = column.association_class_name.demodulize.underscore
      end
    end
  end
end
