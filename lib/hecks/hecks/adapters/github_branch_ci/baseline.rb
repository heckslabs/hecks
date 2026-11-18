# frozen_string_literal: true

require "json"
require_relative "../console_capture"
require_relative "failures"
require_relative "run_wait"

module Hecks
  module Adapters
    class GithubBranchCi
      # What CI said of the commit a coder's branch was cut from: the newest ended CI run of that
      # base, of any event (a train's pull request or a push of main), and the examples it failed.
      # It is the one run that answers "was this failure already there?": a run of a later main
      # can hold failures of commits the branch does not contain.
      class Baseline
        # The refs a branch's base is sought from, in order: the coder cut it from local `main`.
        REFS = %w[main origin/main].freeze

        # @param github [GhCall] the calls to git and GitHub, in the coder's checkout
        def initialize(github)
          @github = github
        end

        # @param sha [String] the coder's head
        # @return [Hash{Symbol => Object}, nil] `run` (its id), `sha` (the base) and `examples` (the
        #   failed examples, empty when the run passed); nil when no base or no ended run of it
        #   can be read, so every failure stays the branch's own
        def of(sha)
          REFS.each do |ref|
            base = merge_base(sha, ref)
            run = base && run_of(base)
            return reading(base, run) if run
          end
          nil
        end

        private

        def merge_base(sha, ref)
          found = @github.run!(["git", "merge-base", sha, ref], "merge-base of #{ref}").strip
          found.empty? ? nil : found
        rescue ConsoleCapture::Failure
          nil
        end

        def run_of(base)
          runs = @github.api("actions/runs?head_sha=#{base}&status=completed&per_page=100").fetch("workflow_runs", [])
          runs.select { |run| run["name"] == RunWait::WORKFLOW }.max_by { |run| run["id"].to_i }
        rescue ConsoleCapture::Failure, JSON::ParserError
          nil
        end

        def reading(base, run)
          { run: run["id"].to_s, sha: base, examples: failed_examples(run["id"].to_s) }
        rescue ConsoleCapture::Failure, JSON::ParserError
          nil
        end

        def failed_examples(run_id)
          examples = Failures.new(@github).of(run_id).flat_map(&:examples)
          examples.uniq
        end
      end
    end
  end
end
