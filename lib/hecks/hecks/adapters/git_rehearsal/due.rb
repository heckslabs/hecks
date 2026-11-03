# frozen_string_literal: true

require_relative "../push_size"
require "hecks/runtime/asking"
require_relative "reading"
require_relative "record"

module Hecks
  module Adapters
    class GitRehearsal
      # Whether a push is due, read from refs git already holds: how many commits local `main` is
      # ahead of `origin/main`, how old the oldest of them is, and how the last quick rehearsal
      # ended.
      class Due
        include Reading

        # Seconds in an hour.
        HOUR = 3600.0

        # @param git [Git] the adapter every git call goes through
        # @param checkout [String] the repository's top level
        # @param place [Hash] `branch:` the local branch ("main"), `remote:` it is pushed to
        # @param limits [Hash, nil] the push size thresholds; the booted world's when nil
        # @param clock [#now] where the age of the oldest commit is read from
        def initialize(git, checkout, limits: nil, clock: Time, **place)
          @limits = limits || PushSize.thresholds(Runtime::Asking.registry)
          @clock = clock
          @git = git
          @checkout = checkout
          @branch = place.fetch(:branch, "main")
          @tracking = "#{place.fetch(:remote, "origin")}/#{@branch}"
        end

        # @return [String] one line:
        #   whether a push is due, the count, the age, the last rehearsal
        # @raise [ConsoleCapture::Failure] when there is no such branch or remote-tracking branch
        def report
          ahead = read("rev-list", "--count", "#{@tracking}..#{@branch}").to_i
          return "push due: no; #{@branch} is level with #{@tracking}; #{last_rehearsal}" if ahead.zero?

          "push due: yes; #{ahead} commit(s) ahead of #{@tracking}; oldest unpushed #{age} hours old; " \
            "#{size(ahead)}#{last_rehearsal}#{gate_note}"
        end

        private

        # The size sentence and its separator once past the threshold, else nothing.
        def size(ahead)
          sentence = PushSize.sentence(ahead, @limits)
          sentence.empty? ? "" : "#{sentence}; "
        end

        def age
          oldest = read("log", "--reverse", "--format=%ct", "#{@tracking}..#{@branch}").lines.first.to_i
          format("%.1f", (@clock.now.to_i - oldest) / HOUR)
        end

        def last_rehearsal = last_of("quick")

        # The train's quick gate is the push gate; say so when no green rehearsal of it is current.
        def gate_note
          entry = Record.new(@git, @checkout).last("quick")
          return "" if entry && entry.verdict == "green" && current?(entry)

          "; the train's quick gate is the push gate and runs at the push: push_rehearsal.rehearse! " \
            "runs it ahead (scope.value=deep also runs the impacted specs; opt-in)"
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
