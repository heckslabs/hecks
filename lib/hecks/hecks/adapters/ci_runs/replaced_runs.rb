# frozen_string_literal: true

require "json"
require_relative "../console_capture"

module Hecks
  module Adapters
    class CiRuns
      # The workflow runs of a pull request's tip that a newer run has replaced. Of the runs that
      # share a workflow, an event and a head commit only the newest by creation time counts; an
      # older one (a ghost left queued by an outage) is dropped from the pull request's checks, so
      # it can neither hold a green pull request nor fail it. Reads GitHub only.
      class ReplacedRuns
        # How a check's link names its workflow run.
        RUN_ID = %r{/actions/runs/(\d+)}

        # The most runs asked of `gh` for one commit.
        LIMIT = "200"

        # @return [String, nil] why the runs could not be read; nil when they were
        attr_reader :unread

        # @param runner [#call] takes `(argv, chdir:)` and answers `[ok, output]`
        # @param checkout [String] the directory `gh` runs in
        # @param tip [String, nil] the pull request's head commit
        def initialize(runner, checkout, tip)
          @ids = replaced(read(runner, checkout, tip.to_s))
        end

        # @param rollup [Array<Hash>, nil] a pull request's `statusCheckRollup`
        # @return [Array<Hash>] the entries not belonging to a replaced run; an entry whose link
        #   names no run is kept
        def keep(rollup) = Array(rollup).reject { |entry| @ids.include?(run_id(entry)) }

        private

        def read(runner, checkout, tip)
          return [] if tip.empty?

          ok, output = runner.call(["gh", "run", "list", "--commit", tip, "--event", "pull_request", "--limit", LIMIT,
                                    "--json", "databaseId,workflowName,event,headSha,createdAt"], chdir: checkout)
          return JSON.parse(output) if ok

          @unread = output.to_s.strip
          []
        rescue JSON::ParserError
          @unread = "gh run list answered no JSON"
          []
        end

        def replaced(runs)
          runs.group_by { |run| run.values_at("workflowName", "event", "headSha") }.values.flat_map { |group| older(group) }
        end

        # The ids of every run in a group but its newest.
        def older(group)
          newest_first = group.sort_by { |run| run["createdAt"].to_s }.reverse
          newest_first.drop(1).map { |run| run["databaseId"].to_s }
        end

        def run_id(entry) = entry.fetch("detailsUrl") { entry["targetUrl"] }.to_s[RUN_ID, 1]
      end
    end
  end
end
