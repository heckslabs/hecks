# frozen_string_literal: true

require_relative "reading"

module Hecks
  module Adapters
    class GitTrain
      # One boarding's work once it holds the line: fetch the remote's branch, then either find
      # the local branch already level with it or push the local branch, and ride again while
      # commits landed during the push are still ahead.
      #
      # A push the remote turns away because its branch moved meanwhile (a push from another
      # machine, which the line does not hold back) is fetched again and retried.
      class Carriage
        include Reading

        # How many times a push the remote turned away for having moved is tried.
        ATTEMPTS = 3

        # How many pushes one boarding makes while the local branch keeps getting ahead.
        RIDES = 3

        # @param git [Git] the adapter every git call goes through
        # @param checkout [String] the repository's top level
        # @param branch [String] the branch to push
        # @param remote [String] the remote to push it to
        # @param config [Array<String>] `-c name=value` words for the push, read by the hook
        def initialize(git, checkout, branch:, remote:, config: [])
          @git = git
          @checkout = checkout
          @branch = branch
          @remote = remote
          @config = config
        end

        # @return [String] the commit the local branch names now
        # @raise [ConsoleCapture::Failure] when there is no such branch
        def local_head = read("rev-parse", "--verify", "refs/heads/#{@branch}^{commit}")

        # Carries the local branch: finds it already on the remote, or pushes it and pushes again
        # while commits that landed meanwhile are still ahead (at most `RIDES` pushes).
        #
        # @param boarded [String] the commit the local branch named at boarding
        # @return [Hash{Symbol => Hash}] the answer `GitTrain#carry` describes
        # @raise [ConsoleCapture::Failure] when the branches conflict or the push is refused
        def carry(boarded)
          fetch
          return carried(boarded) if level?

          ride(boarded)
        end

        private

        # Whether everything the local branch holds is on the remote.
        def level? = ancestor?(local_head, tracking)

        def ride(boarded, reports = [])
          answer = push(boarded)
          reports << answer.dig(:report, :value)
          fetch
          return finish(answer, reports) if level? || reports.size >= RIDES

          ride(boarded, reports)
        end

        def finish(answer, reports)
          answer.merge(report: { value: (reports + leftover).join("; ") })
        end

        # What the local branch still holds that the remote lacks, named so nobody has to look.
        def leftover
          return [] if level?

          waiting = read("log", "--format=%h %s", "#{tracking}..#{@branch}").lines.map(&:strip)
          ["#{waiting.size} commit(s) still ahead of #{tracking}: #{waiting.first(5).join(" | ")}"]
        end

        def push(boarded, attempt = 1)
          before = read("rev-parse", tracking)
          pushed = Bench.new(@git, @checkout, branch: @branch, remote: @remote, config: @config)
                        .push(local_head, tracking)
          return retry_push(boarded, attempt) if pushed == :moved

          answer("pushed", boarded, pushed, pushed_report(before, pushed))
        end

        def retry_push(boarded, attempt)
          raise ConsoleCapture::Failure, "#{tracking} kept moving: #{ATTEMPTS} pushes were turned away" if attempt >= ATTEMPTS

          fetch
          push(boarded, attempt + 1)
        end

        def pushed_report(before, pushed)
          count = read("rev-list", "--count", "#{before}..#{pushed}")
          local = LocalBranch.new(@git, @checkout, @branch).catch_up(pushed)
          "pushed #{short(pushed)} to #{tracking}, #{count} commit(s) new there; #{local}"
        end

        def carried(boarded)
          answer("carried", boarded, nil, "#{short(boarded)} is already on #{tracking}: an earlier push carried it")
        end

        def answer(outcome, boarded, pushed, report)
          { outcome: { value: outcome }, checkout: { value: @checkout }, boarded: { value: boarded },
            pushed: pushed && { value: pushed }, report: { value: report } }.compact
        end

        def fetch = read("fetch", "--quiet", @remote, "+refs/heads/#{@branch}:refs/remotes/#{tracking}")

        def tracking = "#{@remote}/#{@branch}"
      end
    end
  end
end
