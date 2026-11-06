# frozen_string_literal: true

require "json"
require_relative "pull_request_boarding"

module Hecks
  module Adapters
    class GitTrain
      # Queues a queued boarding's pull request for merge, once GitHub reports it clean: no failing
      # check, none still running, and no conflict. Anything else is refused, with the reason, and
      # nothing changes.
      class PrQueue
        # @param runner [#call] runs `gh` with its arguments, answering `[ok, output]`
        # @param checkout [String] the checkout the boarding was made in
        def initialize(runner, checkout)
          @runner = runner
          @checkout = checkout
        end

        # @param boarded [String] the commit the boarding queued
        # @return [Hash{Symbol => Hash}] `outcome:` `queued` or `refused`, and `report:`
        # @raise [ConsoleCapture::Failure] when `gh` cannot read the PR
        def answer(boarded)
          branch = PullRequestBoarding.branch_for(boarded)
          ok, output = @runner.call(
            ["gh", "pr", "view", branch, "--json", "isDraft,mergeStateStatus,statusCheckRollup"], chdir: @checkout
          )
          raise ConsoleCapture::Failure, "could not read the PR for #{branch}: #{output.to_s.strip}" unless ok

          pr = JSON.parse(output.to_s)
          blockers = blockers_of(pr)
          return refused(branch, blockers) unless blockers.empty?

          queue(branch, pr)
        end

        private

        def blockers_of(pr)
          checks = Array(pr["statusCheckRollup"])
          blockers = []
          blockers << "a check failed" if checks.any? { |check| check["conclusion"] == "FAILURE" }
          blockers << "a check is still running" if checks.any? { |check| check["status"] != "COMPLETED" }
          blockers << "it conflicts with main" if pr["mergeStateStatus"] == "DIRTY"
          blockers
        end

        def queue(branch, pr)
          @runner.call(["gh", "pr", "ready", branch], chdir: @checkout) if pr["isDraft"]
          ok, output = @runner.call(["gh", "pr", "merge", branch, "--auto"], chdir: @checkout)
          raise ConsoleCapture::Failure, "could not queue #{branch}: #{output.to_s.strip}" unless ok

          { outcome: { value: "queued" }, report: { value: "#{branch} queued to merge once its checks pass" } }
        end

        def refused(branch, blockers)
          { outcome: { value: "refused" }, report: { value: "#{branch} not queued: #{blockers.join("; ")}" } }
        end
      end
    end
  end
end
