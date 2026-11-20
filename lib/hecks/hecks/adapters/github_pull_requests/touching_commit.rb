# frozen_string_literal: true

require "json"
require_relative "../console_capture"
require_relative "../git_rehearsal/spec_map"

module Hecks
  module Adapters
    class GithubPullRequests
      # Names the commit of a pull request a failed job is attributed to: the newest one whose
      # changed files are the failing specs, or map to them through the push rehearsal's map from
      # changed files to specs. It is a measure, not a proof: a later commit touching the same
      # specs is named before an earlier one, so the answer says what was measured. Each commit's
      # files are read once through `gh`, and only the newest `CAP` commits are read.
      class TouchingCommit
        # How many of the pull request's newest commits are read.
        CAP = 20

        # The most specs the map is asked for: enough that none of a change's specs is cut off.
        LIMIT = 100_000

        # What a job that named no spec is told.
        NO_SPEC = "not attributed: no spec failed by name"

        # @param github [#call] takes the `gh` arguments and answers their stdout; raises on failure
        # @param checkout [String] the directory whose `spec/` the map reads
        # @param commits [Array<Hash>, nil] the pull request's commits, oldest first, each with its
        #   `oid` and `messageHeadline`
        def initialize(github, checkout, commits)
          @gh = github
          @checkout = checkout
          @commits = Array(commits)
          @files = {}
        end

        # @param specs [Array<String>] the spec files a failed job names
        # @return [String] the newest commit touching them, or why none is named
        def name(specs)
          return NO_SPEC if specs.empty?

          found = read.find { |commit| touches?(commit, specs) }
          return "not attributed: #{none_read}" unless found

          "newest commit touching the failing specs: #{found["oid"].to_s[0, 10]} #{found["messageHeadline"]}"
        end

        private

        # The commits that are read, newest first.
        def read = @commits.last(CAP).reverse

        def none_read
          rest = @commits.size - read.size
          "none of the #{read.size} newest commits touches the failing specs" \
            "#{" (#{rest} older not read)" if rest.positive?}"
        end

        def touches?(commit, specs)
          changed = files(commit["oid"].to_s)
          return false if changed.empty?

          specs.intersect?(changed) || specs.intersect?(mapped(changed))
        end

        def mapped(changed) = GitRehearsal::SpecMap.new(@checkout).map(changed, limit: LIMIT).specs

        # The paths one commit changes; none when GitHub does not name them.
        def files(oid)
          @files[oid] ||= Array(JSON.parse(@gh.call("api", "repos/{owner}/{repo}/commits/#{oid}"))["files"])
                          .map { |file| file["filename"].to_s }
        rescue ConsoleCapture::Failure, JSON::ParserError, TypeError
          @files[oid] = []
        end
      end
    end
  end
end
