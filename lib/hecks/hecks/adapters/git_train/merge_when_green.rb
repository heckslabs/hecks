# frozen_string_literal: true

require "json"
require_relative "../console_capture"
require_relative "../github_pull_requests"

module Hecks
  module Adapters
    class GitTrain
      # The boarding of a repository that disallows auto-merge: the train waits for the PR's
      # required checks itself, then squash-merges it through `GithubPullRequests#squash`, the
      # path `ReviewRequest.take!` takes. `--admin` is never passed, so branch protection stands.
      #
      # Green, it answers `pushed` with the merge commit. A failed or cancelled required check
      # answers `checks_failed` naming each one, and the PR stays open.
      class MergeWhenGreen
        # Seconds between two reads of the checks.
        INTERVAL = 30
        # How many reads are made before the wait gives up (two hours at the default interval).
        READS = 240
        # `gh pr checks` buckets that mean a check did not pass.
        FAILED = %w[fail cancel].freeze
        # `gh pr checks` buckets that mean a check needs nothing more.
        DONE = %w[pass skipping].freeze

        # @param runner [#call] takes `(argv, chdir:)` and answers `[ok, output]` for `gh`
        # @param checkout [String] the repository's top level
        # @param pause [#call] takes the seconds to wait; a spec replaces it
        # @param reads [Integer] how many times the checks are read before giving up
        def initialize(runner, checkout, pause: ->(seconds) { sleep(seconds) }, reads: READS)
          @runner = runner
          @checkout = checkout
          @pause = pause
          @reads = reads
        end

        # @param branch [String] the PR's head branch
        # @param number [String] the PR's number
        # @param boarded [String] the commit the boarding carries
        # @return [Hash{Symbol => Hash}] `outcome:` `pushed` (with `pushed:`, the merge commit) or
        #   `checks_failed`, and `report:`
        # @raise [ConsoleCapture::Failure] when the checks do not settle in time, or GitHub refuses
        #   the merge or names no merge commit
        def settle(branch, number, boarded)
          failed = wait_for(branch)
          return failed_answer(branch, failed) unless failed.empty?

          answer = GithubPullRequests.new(runner: method(:gh)).squash(number: number)
          return merged(boarded) if answer.dig(:outcome, :value) == "merged"

          follow(branch, boarded)
        end

        private

        # The merge was accepted but not made (a merge queue): the PR is read until it merges.
        # `pushed` is answered only for a merged PR; one the queue closed unmerged is a fault.
        def follow(branch, boarded)
          @reads.times do
            seen = PullRequestBoarding::Observation.new(@runner, @checkout).answer(boarded)
            return { outcome: { value: "pushed" }, pushed: seen[:pushed], report: seen[:report] } if seen[:pushed]

            dropped!(branch, seen[:state]) unless seen[:state] == "OPEN"
            @pause.call(INTERVAL)
          end
          raise ConsoleCapture::Failure, "#{branch} is queued but did not merge in #{@reads * INTERVAL}s; PR left queued"
        end

        def dropped!(branch, state)
          raise ConsoleCapture::Failure, "the merge queue dropped #{branch} (#{state.to_s.downcase}) without merging it"
        end

        def wait_for(branch)
          @reads.times do
            seen = checks(branch)
            failed = seen.select { |check| FAILED.include?(check["bucket"]) }
            return failed.map { |check| check["name"] } unless failed.empty?
            return [] if seen.any? && seen.all? { |check| DONE.include?(check["bucket"]) }

            @pause.call(INTERVAL)
          end
          raise ConsoleCapture::Failure, "required checks of #{branch} did not finish in #{@reads * INTERVAL}s; PR left open"
        end

        # The required checks as `gh` reports them; output that is not JSON (no checks yet) is none.
        def checks(branch)
          argv = ["gh", "pr", "checks", branch, "--required", "--json", "name,bucket"]
          _ok, output = @runner.call(argv, chdir: @checkout)
          JSON.parse(output.to_s)
        rescue JSON::ParserError
          []
        end

        def failed_answer(branch, names)
          { outcome: { value: "checks_failed" },
            report:  { value: "checks failed on #{branch}: #{names.join(", ")}; PR left open" } }
        end

        def merged(boarded)
          seen = PullRequestBoarding::Observation.new(@runner, @checkout).answer(boarded)
          { outcome: { value: "pushed" }, pushed: seen[:pushed], report: seen[:report] }
        end

        # `GithubPullRequests`' runner form, over the train's: `[stdout, stderr, success]`.
        def gh(arguments)
          ok, output = @runner.call(["gh", *arguments], chdir: @checkout)
          [output.to_s, "", ok]
        end
      end
    end
  end
end
