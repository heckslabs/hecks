# frozen_string_literal: true

require_relative "baseline"
require_relative "failures"
require_relative "summary"

module Hecks
  module Adapters
    class GithubBranchCi
      # What one ended run says: every job that failed, and which of them failed only on examples
      # the run of the branch's base failed too. A job that names no example (a lint, a build, a
      # drift check) is never inherited, so a new break of its own stays the branch's. These are
      # facts; whether the branch passed is drawn by the bluebook's policies from them.
      class Verdict
        # @param github [GhCall] the calls to GitHub
        # @param run [Hash] the ended run
        # @param pushed_at [Time] when the branch was pushed
        def initialize(github, run, pushed_at)
          @github = github
          @run = run
          @pushed_at = pushed_at
        end

        # @param sha [String] the head the run checked
        # @param number [String] the draft's number
        # @return [Hash{Symbol => Hash}] the port's answer: `failing` names every failed job and
        #   `inherited` those of them the base failed too, in the same order, each empty when none
        # @raise [ConsoleCapture::Failure] when the run's jobs cannot be read
        def answer(sha, number)
          failed = Failures.new(@github).of(@run["id"].to_s)
          base = failed.empty? ? nil : Baseline.new(@github).of(sha)
          inherited = failed.select { |failure| inherited?(failure, base) }
          { sha: { value: sha }, number: { value: number }, ci_run: { value: @run["id"].to_s },
            failing: named(failed), inherited: named(inherited),
            report: { value: Summary.new(@run, @pushed_at).text(failed - inherited, inherited, base) } }
        end

        private

        def inherited?(failure, base)
          return false unless base && failure.examples.any?

          (failure.examples - base[:examples]).empty?
        end

        def named(failures) = { value: failures.map(&:name).join(", ") }
      end
    end
  end
end
