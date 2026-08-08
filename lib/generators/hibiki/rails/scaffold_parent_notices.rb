# frozen_string_literal: true

module Hibiki
  module Rails
    module Generators
      # What the generator says about the model a belongs_to points AT.
      #
      # One line per PARENT file, from the reports ScaffoldParentInjection
      # leaves behind. Split from that module along the report hash, which is
      # the seam it already had: one side decides and writes, this one explains.
      #
      # What this replaced warned about a missing has_many only when the fields
      # came from an argument list — the one path that cannot look at the parent
      # at all — so it spoke when it did not know and stayed silent when it did.
      #
      # No extra green `inject` line here: Thor already prints one per file it
      # touches, and with several belongs_tos a second would bury these.
      module ScaffoldParentNotices
        # Each injected piece with its own reason attached, so a parent that
        # needed only one of them is never told about the other.
        PARENT_PIECES = {
          has_many: "the has_many with a dependent: option",
          ping: "the cross-resource after_commit"
        }.freeze

        private

        def parent_notices
          @parent_reports.each do |report|
            say_status :assoc, parent_message(report), :blue
            say_status :assoc, parent_collision_message(report), :blue if report[:collides]
          end
        end

        def parent_message(report)
          case report[:outcome]
          when :injected then injected_message(report)
          when :already_wired then already_wired_message(report)
          when :no_file then no_file_message(report)
          when :self_referential then self_referential_message(report)
          end
        end

        def injected_message(report)
          "#{report[:path]} was MODIFIED: added #{parent_pieces(report)}#{kept_clause(report)}"
        end

        def parent_pieces(report) = PARENT_PIECES.values_at(*report[:pieces]).join("; and ")

        # Named even when something else was written: a user who chose
        # `dependent: :restrict_with_error` should hear that we looked.
        def kept_clause(report)
          return "" if report[:kept].empty?

          ". Its own #{kept_names(report)} was left alone"
        end

        def kept_names(report)
          report[:kept].map { it == :has_many ? "has_many :#{plural_name}" : "#{ping_marker} ping" }.to_sentence
        end

        def already_wired_message(report)
          "#{report[:columns].first.association_class_name} already declares #{kept_names(report)}, left alone"
        end

        def no_file_message(report)
          "there is no #{report[:path]} to edit, add the snippet above for " \
            "#{report[:columns].first.association_class_name} by hand: #{parent_pieces(report)}"
        end

        def self_referential_message(report)
          column = report[:columns].first

          "#{class_name}##{column.association_name} points back at #{class_name}, so the ping is already " \
            "covered by #{model_path}'s own after_commit — but the has_many is not, and no plural of " \
            "`#{column.association_name}` is a generator's to invent. Add it yourself, e.g. `has_many " \
            ":children, foreign_key: :#{column.name}, inverse_of: :#{column.association_name}, " \
            "dependent: #{dependent_option(column)}`, or #{singular_name}.destroy! raises InvalidForeignKey"
        end

        def parent_collision_message(report)
          column = report[:columns].first

          "#{report[:columns].map { ":#{it.association_name}" }.to_sentence} all point at " \
            "#{column.association_class_name}, so one `has_many :#{plural_name}` cannot serve them — only " \
            "the ping was injected. Name the halves yourself (`has_many :#{plural_name}, foreign_key: " \
            ":#{column.name}, dependent: #{dependent_option(column)}`) or " \
            "#{parent_variable(column)}.destroy! raises InvalidForeignKey"
        end
      end
    end
  end
end
