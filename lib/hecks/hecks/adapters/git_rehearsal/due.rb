# frozen_string_literal: true

require_relative "reading"
require_relative "record"

module Hecks
  module Adapters
    class GitRehearsal
      # Whether a push is due, read from refs git already holds: how many commits local `main` is
      # ahead of `origin/main`, how old the oldest of them is, and how the last quick and the last
      # full rehearsal ended.
      class Due
        include Reading

        # Seconds in an hour.
        HOUR = 3600.0

        # @param git [Git] the adapter every git call goes through
        # @param checkout [String] the repository's top level
        # @param branch [String] the local branch
        # @param remote [String] the remote it is pushed to
        def initialize(git, checkout, branch: "main", remote: "origin")
          @git = git
          @checkout = checkout
          @branch = branch
          @tracking = "#{remote}/#{branch}"
        end

        # @return [String] one line:
        #   whether a push is due, the count, the age, the last rehearsal
        # @raise [ConsoleCapture::Failure] when there is no such branch or remote-tracking branch
        def report
          ahead = read("rev-list", "--count", "#{@tracking}..#{@branch}").to_i
          return "push due: no; #{@branch} is level with #{@tracking}; #{last_rehearsal}" if ahead.zero?

          "push due: yes; #{ahead} commit(s) ahead of #{@tracking}; oldest unpushed #{age} hours old; " \
            "#{last_rehearsal}#{full_needed}"
        end

        private

        def age
          oldest = read("log", "--reverse", "--format=%ct", "#{@tracking}..#{@branch}").lines.first.to_i
          format("%.1f", (Time.now.to_i - oldest) / HOUR)
        end

        # Both scopes' last result; a push needs a full one, so a missing or stale one says so.
        def last_rehearsal = "#{last_of("quick")}; #{last_of("full")}"

        # A push needs a full rehearsal of the current branch; say so when there is none.
        def full_needed
          entry = Record.new(@git, @checkout).last("full")
          return "" if entry && entry.verdict == "green" && current?(entry)

          "; a push needs a green full rehearsal of the current #{@branch}: push_rehearsal.rehearse! " \
            "(scope.value=deep also runs the impacted specs; opt-in)"
        end

        def last_of(scope)
          entry = Record.new(@git, @checkout).last(scope)
          return "last #{scope}: none yet" unless entry

          "last #{scope}: #{entry.verdict}#{failed(entry)} on #{short(entry.commit)} (#{currency(entry)})"
        end

        def failed(entry) = entry.failed.empty? ? "" : " (#{entry.failed.tr(",", ", ")})"

        def currency(entry) = current?(entry) ? "the current #{@branch}" : "#{@branch} has moved since"

        def current?(entry) = read("rev-parse", "--verify", "refs/heads/#{@branch}^{commit}") == entry.commit
      end
    end
  end
end
