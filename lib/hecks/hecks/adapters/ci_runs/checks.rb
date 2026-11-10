# frozen_string_literal: true

require "hecks/check_conclusion"

module Hecks
  module Adapters
    class CiRuns
      # The checks GitHub lists on a pull request (`statusCheckRollup`), measured and not judged:
      # how many there are, how many have concluded and which concluded without success. A check run
      # carries `status` and `conclusion`; a commit status carries `state`.
      class Checks
        # The states of a commit status that have not concluded.
        UNSETTLED = %w[PENDING EXPECTED].freeze

        # @param rollup [Array<Hash>, nil] the pull request's `statusCheckRollup`
        def initialize(rollup)
          @entries = Array(rollup)
        end

        # @return [Integer] how many checks the pull request lists
        def total = @entries.size

        # @return [Integer] how many of them have concluded
        def done = @entries.count { |entry| concluded?(entry) }

        # @return [Array<String>] the names of the checks that concluded without success
        def failed = @entries.select { |entry| concluded?(entry) && !clean?(entry) }.map { |entry| name(entry) }

        # @return [Boolean] whether a check failed and no check is left running
        def failed_and_complete? = !failed.empty? && done == total

        # @return [String] the counts for a report: `"3 of 12 checks"`
        def counts = "#{done} of #{total} checks"

        private

        def concluded?(entry)
          return entry["status"] == "COMPLETED" if entry.key?("status")

          !UNSETTLED.include?(entry["state"].to_s)
        end

        def clean?(entry) = Hecks::CheckConclusion.clean?(entry.fetch("conclusion") { entry["state"] }.to_s.downcase)

        def name(entry) = entry.fetch("name") { entry["context"] }.to_s
      end
    end
  end
end
