# frozen_string_literal: true

require "json"
require_relative "console_capture"
require_relative "ci_runs/pull_request"
require_relative "ci_runs/replaced_runs"
require_relative "ci_runs/train_pr_failure"
require_relative "ci_runs/ci_start"
require_relative "main_integration/command_runner"

module Hecks
  module Adapters
    # The `CiRuns` port's adapter for `Integration.Observe`: reads, through `gh`, the CI run of a
    # push of main at a landed commit, or at the commit GitHub merged the boarding's train pull
    # request as. It answers `running` while the pull request is open, there is no run yet or it has
    # not completed, `merged` when the pull request merged and CI on its merge commit has not
    # completed, `passed` when it succeeded, `failed` with the jobs that did not succeed, and
    # `closed` when the pull request was closed without merging (main never moved). Each answer
    # echoes `pulled`, whether the run was already seen merged.
    class CiRuns
      # The workflow whose run is read, as GitHub names it.
      WORKFLOW = "CI"

      class << self
        # @return [#call, nil] takes `(argv, chdir:)` and answers `[ok, output]`; the command
        #   runner when nil. A spec replaces it with a fake GitHub.
        attr_accessor :runner

        # @return [#now, nil] the clock a pull request's age is measured by; `Time` when nil
        attr_accessor :clock
      end

      # @param aggregate [Object, nil] unused
      # @param settings [Hash] unused
      # @param root [String, nil] unused
      def initialize(aggregate: nil, settings: {}, root: nil)
        @checkout = nil
      end

      # @param held [Hash] the `Integration` record: `landed` and `checkout`
      # @return [Hash{Symbol => Hash}] `outcome:` (`running`, `passed` or `failed`) and `report:`
      # @raise [ConsoleCapture::Failure] when `gh` cannot read the pull request or the run; a red
      #   pull request whose failed jobs cannot be read answers `running` instead
      def watch(**held)
        landed = plain(held[:landed]).to_s
        @checkout = plain(held[:checkout]) || Dir.pwd
        @pulled = plain(held[:pulled]) == true
        pull = PullRequest.new(runner, @checkout, landed).read
        return observe(landed, landed) unless pull

        via_pull_request(landed, pull)
      end

      # Reruns the failed jobs of one CI run, once the bluebook has decided to.
      #
      # @param held [Hash] the `TrainPr` record: `ci_run`, and `pr` for the report
      # @return [Hash{Symbol => Hash}] `report:`
      # @raise [ConsoleCapture::Failure] when `gh` refuses
      def restart(**held)
        id = plain(held[:ci_run]).to_s
        @checkout = Dir.pwd
        ok, output = runner.call(["gh", "run", "rerun", "--failed", id], chdir: @checkout)
        raise ConsoleCapture::Failure, "gh run rerun failed: #{output.to_s.strip}" unless ok

        { report: { value: "reran the failed jobs of CI run #{id} (PR #{plain(held[:pr])})" } }
      end

      private

      # A boarding that went as a pull request is judged on the commit GitHub merged it as: running
      # while the pull request is open, closed (main never moved) when it was closed unmerged.
      def via_pull_request(landed, pull)
        number = pull["number"]
        case pull["state"]
        when "MERGED" then observe(landed, pull.dig("mergeCommit", "oid") || landed, merged: number)
        when "CLOSED" then closed_pull_request(landed, pull)
        else open_pull_request(landed, pull)
        end
      end

      # A pull request closed while the pipeline reopens it to start its CI is still running, so a
      # beat between the close and the reopen does not free the line; any other one is closed.
      def closed_pull_request(landed, pull)
        number = pull["number"]
        return answer("running", "#{landed[0, 10]}: PR #{number} is being reopened to start CI") if
          ReopenMarker.reopening?(pull["comments"])

        answer("closed", "#{landed[0, 10]}: PR #{number} closed without merging")
      end

      # An open pull request whose checks all concluded with a failure answers `pr_failed` and the
      # facts of the failure. One with no check and no started CI run answers `awaiting_ci`, one
      # with checks `checking`, and one whose CI run started before GitHub lists its checks
      # `running`; each carries the facts of its CI start, which the bluebook's bounds judge.
      def open_pull_request(landed, pull)
        replaced = ReplacedRuns.new(runner, @checkout, pull.dig("commits", -1, "oid"))
        checks = Checks.new(replaced.keep(pull["statusCheckRollup"]))
        return pr_failed(landed, pull) if checks.failed_and_complete?

        start = CiStart.new(pull, checks, replaced.newest_status(WORKFLOW), now)
        answer(start.outcome, still_open(landed, pull, start, replaced)).merge(start.facts)
      end

      def pr_failed(landed, pull)
        branch = GitTrain::PullRequestBoarding.branch_for(landed)
        facts = TrainPrFailure.new(runner, @checkout, branch, landed).facts(pull)
        answer("pr_failed", facts.delete(:report)).merge(facts.transform_values { |value| { value: value } })
      rescue ConsoleCapture::Failure => e
        answer("running", unreadable(landed, pull, e))
      end

      # A red pull request whose failure `gh` cannot be read for (a 5xx, a missing run, no `gh`) is
      # still watched, so the next observation reads it again and records it once it can.
      def unreadable(landed, pull, error)
        "#{landed[0, 10]}: PR #{pull["number"]} CI failed; failed jobs unreadable (#{error.message}); " \
          "retrying next observation"
      end

      def still_open(landed, pull, start, replaced)
        return "#{landed[0, 10]}: #{start.report}" if start.unstarted?

        text = "#{landed[0, 10]}: PR #{pull["number"]} not merged yet (#{start.counts})"
        replaced.unread ? "#{text}; replaced runs unread: #{replaced.unread}" : text
      end

      # @param merged [Object, nil] the pull request's number when it merged: CI still running on
      #   its merge commit then answers `merged` (main is pulled), not `running`
      def observe(landed, commit, merged: nil)
        run = latest_run(commit)
        return unfinished(landed, merged, "no #{WORKFLOW} run yet for #{commit[0, 10]}") unless run
        return unfinished(landed, merged, "#{WORKFLOW} run #{run["databaseId"]} is #{run["status"]}") unless
          run["status"] == "completed"

        verdict(landed, run)
      end

      def unfinished(landed, merged, text)
        return answer("running", "#{landed[0, 10]}: #{text}") unless merged

        answer("merged", "#{landed[0, 10]}: PR #{merged} merged; #{text}")
      end

      # The run of the commit on main, or nil when GitHub has none for it yet.
      def latest_run(landed)
        gh("run", "list", "--workflow", WORKFLOW, "--branch", "main", "--event", "push", "--commit", landed,
           "--json", "databaseId,status,conclusion", "--limit", "1").first
      end

      def verdict(landed, run)
        id = run["databaseId"]
        return answer("passed", "#{landed[0, 10]}: #{WORKFLOW} run #{id} passed") if run["conclusion"] == "success"

        answer("failed", "#{landed[0, 10]}: #{WORKFLOW} run #{id} #{run["conclusion"]}; failed jobs: #{failed_jobs(id)}")
      end

      def failed_jobs(id)
        jobs = gh("run", "view", id.to_s, "--json", "jobs").fetch("jobs", [])
        names = jobs.reject { |job| Hecks::CheckConclusion.clean?(job["conclusion"]) }.map { |job| job["name"] }
        names.empty? ? "none named" : names.join(", ")
      end

      def gh(*args)
        ok, output = runner.call(["gh", *args], chdir: @checkout)
        raise ConsoleCapture::Failure, "gh #{args.first(2).join(" ")} failed: #{output.to_s.strip}" unless ok

        JSON.parse(output)
      rescue JSON::ParserError
        raise ConsoleCapture::Failure, "gh #{args.first(2).join(" ")} answered no JSON"
      end

      def answer(outcome, report)
        { outcome: { value: outcome }, report: { value: report }, checkout: { value: @checkout }, pulled: { value: @pulled } }
      end

      def runner = self.class.runner || MainIntegration::CommandRunner.new

      def now = (self.class.clock || Time).now

      def plain(argument) = argument.is_a?(Hash) ? argument[:value] : argument
    end
  end
end
