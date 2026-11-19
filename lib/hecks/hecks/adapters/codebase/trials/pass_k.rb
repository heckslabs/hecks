# frozen_string_literal: true

module Hecks
  module Adapters
    module Codebase
      class Trials
        # pass^k from a trial history: the chance that k runs in a row all pass, which is what a
        # landing that reruns a red spec until green leans on. A subject that passes 75 percent of
        # its runs passes three in a row about 42 percent of the time.
        #
        # The batch figure multiplies its subjects' pass^k, which is the bound for runs that are
        # independent; trials that fail from one shared limit are not, and fail together more often.
        # Only subjects with at least `MIN_RUNS` runs count, since one pass says little.
        module PassK
          # The runs in a row the figure is for.
          K = 3

          # The fewest runs a subject needs to count in a batch's figure.
          MIN_RUNS = 2

          # One subject's history.
          #
          # @!attribute [r] subject
          #   @return [String] the spec file or check
          # @!attribute [r] runs
          #   @return [Integer] how many runs it was in
          # @!attribute [r] passes
          #   @return [Integer] how many of them it passed
          Tally = Struct.new(:subject, :runs, :passes) do
            # @return [Float] the share of runs it passed
            def rate = passes.fdiv(runs)

            # @param row [Integer] the runs in a row
            # @return [Float] the chance it passes that many runs in a row
            def pass_k(row = K) = rate**row

            # @return [Boolean] whether it failed a run
            def failed? = passes < runs

            # @return [Boolean] whether it has runs enough to count in a batch's figure
            def counted? = runs >= MIN_RUNS
          end

          module_function

          # @param rows [Array<Hash>] trial rows with `subject` and `passed`
          # @param subjects [Array<String>] the subjects to tally, in order
          # @return [Array<Tally>] each subject's history; a subject with no rows is left out
          def tallies(rows, subjects)
            grouped = rows.group_by { |row| row["subject"] }
            subjects.filter_map do |subject|
              mine = grouped.fetch(subject, [])
              Tally.new(subject, mine.size, mine.count { |row| row["passed"] }) unless mine.empty?
            end
          end

          # @param tallies [Array<Tally>] the batch's subjects
          # @param row [Integer] the runs in a row
          # @return [Float, nil] the product of the counted subjects' pass^k; nil when none counts
          def batch(tallies, row = K)
            counted = tallies.select(&:counted?)
            counted.empty? ? nil : counted.map { |tally| tally.pass_k(row) }.reduce(:*)
          end
        end
      end
    end
  end
end
