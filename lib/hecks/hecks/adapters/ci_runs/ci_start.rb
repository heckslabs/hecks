# frozen_string_literal: true

require "time"
require_relative "reopen_marker"

module Hecks
  module Adapters
    class CiRuns
      # Whether an open train pull request's CI has started, as facts: the checks GitHub lists, the
      # minutes since the pull request opened, the status of the newest CI run of its tip and
      # whether the pipeline already reopened it. It measures and judges nothing: the bounds are
      # the bluebook's (`AwaitTheUnstartedTrainPrCi`, `ReopenTheUnstartedTrainPr`).
      class CiStart
        # The statuses of a run GitHub has not started; `none` is a tip with no CI run at all.
        UNSTARTED = %w[none queued waiting requested pending].freeze

        # @param pull [Hash] the pull request as `gh pr view` answers it
        # @param checks [Checks] its checks, replaced runs left out
        # @param ci_status [String] the newest CI run's status, `none` when there is none
        # @param now [Time] the clock's answer
        def initialize(pull, checks, ci_status, now)
          @pull = pull
          @checks = checks
          @ci_status = ci_status
          @now = now
        end

        # @return [Boolean] whether GitHub lists no check and no CI run has started
        def unstarted? = !listed? && UNSTARTED.include?(@ci_status)

        # @return [Boolean] whether GitHub lists any check on the pull request
        def listed? = @checks.total.positive?

        # @return [String] the counts of its checks for a report: `"3 of 12 checks"`
        def counts = @checks.counts

        # @return [String] `awaiting_ci` when its CI has not started, `checking` when GitHub lists
        #   checks, `running` when a CI run started before GitHub lists its checks
        def outcome
          return "awaiting_ci" if unstarted?

          listed? ? "checking" : "running"
        end

        # @return [Hash{Symbol => Hash}] `pr`, `checks`, `waited`, `ci_status` and `reopened`
        def facts
          { pr: @pull["number"].to_s, checks: @checks.total, waited: waited, ci_status: @ci_status,
            reopened: ReopenMarker.reopened?(@pull["comments"]) }.transform_values { |value| { value: value } }
        end

        # @return [String] the report of a pull request whose CI has not started
        def report
          "PR #{@pull["number"]} has no check results; newest CI run is #{@ci_status}; " \
            "waited #{waited} minutes since it opened"
        end

        private

        # Whole minutes since the pull request opened; 0 when GitHub gave no time.
        def waited
          opened = @pull["createdAt"].to_s
          opened.empty? ? 0 : [((@now - Time.iso8601(opened)) / 60).floor, 0].max
        end
      end
    end
  end
end
