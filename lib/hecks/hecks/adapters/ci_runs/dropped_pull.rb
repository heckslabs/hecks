# frozen_string_literal: true

require "json"
require_relative "../console_capture"
require_relative "../gh_rest"

module Hecks
  module Adapters
    class CiRuns
      # Whether an open train pull request was dropped by the merge queue: every check green and
      # its auto-merge gone, as when main moved under it. GitHub's mergeability is read once, over
      # REST, and only for such a pull request: `dirty` means it does not merge cleanly now
      # (`conflicted`), an empty answer means GitHub has not computed it yet, and the pull
      # request is read again on the next beat.
      class DroppedPull
        # @param runner [#call] takes `(argv, chdir:)` and answers `[ok, output]`
        # @param checkout [String] the directory `gh` runs in
        # @param pull [Hash] the pull request as `PullRequest#read` answers it
        # @param landed [String] the boarded commit
        def initialize(runner, checkout, pull, landed)
          @runner = runner
          @checkout = checkout
          @pull = pull
          @landed = landed
        end

        # @param checks [Checks] the pull request's checks
        # @return [Hash, nil] `outcome` (`dropped`, `conflicted` or `running`), `report` and `pr`;
        #   nil when the pull request was not dropped
        def read(checks)
          return nil unless dropped?(checks)

          outcome = outcome_of(mergeable_state)
          { outcome: outcome, pr: @pull["number"].to_s,
            report: "#{@landed[0, 10]}: PR #{@pull["number"]} is open and green with auto-merge off (#{outcome})" }
        end

        private

        def dropped?(checks)
          @pull["state"] == "OPEN" && @pull["autoMergeRequest"].nil? && checks.passed_and_complete?
        end

        def outcome_of(state)
          return "running" if state.empty? || state == "unknown"

          state == "dirty" ? "conflicted" : "dropped"
        end

        def mergeable_state = GhRest.new(method(:api)).mergeable_state(@pull["number"])

        def api(*arguments)
          ok, output = @runner.call(["gh", *arguments], chdir: @checkout)
          raise ConsoleCapture::Failure, "gh api failed: #{output.to_s.strip}" unless ok

          JSON.parse(output.to_s)
        end
      end
    end
  end
end
