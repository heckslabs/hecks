# frozen_string_literal: true

require_relative "../area_overlap"

module Hecks
  module Adapters
    class Dispatching
      # The known traps a coder is briefed with, and the kinds a CI failure matches. It reads the
      # lessons it is given and decides nothing beyond the area rule in {AreaOverlap}.
      class LessonTraps
        # @param lessons [Array<Hash>] each lesson's `kind`, `signature` (Array), `cause`, `check`,
        #   `fix`, `always` (`"yes"` or `"no"`) and `area` (Array)
        def initialize(lessons)
          @lessons = lessons
        end

        # @param area [Array<String>] the area the Work item may edit
        # @return [Array<String>] one line per lesson briefed: its kind, its fix and its check
        def for(area)
          @lessons.select { |lesson| lesson[:always] == "yes" || overlaps?(lesson[:area], area) }
                  .map { |lesson| line(lesson) }
        end

        # @param lessons [Array<Hash>] the lessons, as {#initialize} takes them
        # @param text [String] CI output, a failing spec's path or name, or an error line
        # @return [Array<String>] the kinds whose signature appears in the text, in lesson order
        def self.match(lessons, text)
          lessons.select { |lesson| lesson[:signature].any? { |signature| text.include?(signature) } }
                 .map { |lesson| lesson[:kind] }
        end

        private

        def overlaps?(lesson_area, area)
          lesson_area.any? { |mine| area.any? { |theirs| AreaOverlap.overlap?(mine, theirs) } }
        end

        def line(lesson)
          "#{lesson[:kind]}: fix: #{lesson[:fix]} Check before the push: #{lesson[:check]}"
        end
      end
    end
  end
end
