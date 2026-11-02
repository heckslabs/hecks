# frozen_string_literal: true

require_relative "reading"

module Hecks
  module Adapters
    class GitTrain
      # One boarding's work once it holds the line: fetch the remote's branch, then either find
      # the boarded commit already on it or push exactly that commit.
      #
      # What is pushed is the commit the boarding named, never the local branch as it stands at push
      # time: a branch that moved on since is refused by name (its new commits were not minted for
      # or settled), and a remote that moved so the commit is not built on it is refused too.
      # Commits that land during the push stay local and are named in the report.
      #
      # A push the remote turns away because its branch moved meanwhile (a push from another
      # machine, which the line does not hold back) is fetched again and retried.
      class Carriage
        include Reading

        # How many times a push the remote turned away for having moved is tried.
        ATTEMPTS = 3

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

        # Says the push hold is kept, so a branch that moved is named as a hold broken.
        #
        # @return [Carriage] self
        def under_hold
          @held = true
          self
        end

        # @return [String] the commit the local branch names now
        # @raise [ConsoleCapture::Failure] when there is no such branch
        def local_head = read("rev-parse", "--verify", "refs/heads/#{@branch}^{commit}")

        # Carries one commit: finds it already on the remote, or pushes exactly it.
        #
        # @param boarded [String] the commit to carry, which the local branch must still name
        # @return [Hash{Symbol => Hash}] the answer `GitTrain#carry` describes
        # @raise [ConsoleCapture::Failure] when the branch moved since boarding, the remote's branch
        #   moved so the commit is not built on it, or the push is refused
        def carry(boarded)
          fetch
          moved_since!(boarded)
          return carried(boarded) if ancestor?(boarded, tracking)

          finish(push(boarded), boarded)
        end

        private

        # Refuses, pushing nothing, when the local branch names another commit than the boarded one.
        def moved_since!(boarded)
          now = local_head
          return if now == boarded

          raise ConsoleCapture::Failure, moved_words(boarded, now)
        end

        def moved_words(boarded, now)
          return "#{@branch} moved from #{short(boarded)} to #{short(now)} during the push hold: board again" if @held

          "#{@branch} moved since boarding (boarded #{short(boarded)}, now #{short(now)}): board again"
        end

        def finish(answer, boarded)
          answer.merge(report: { value: [answer.dig(:report, :value), *leftover(boarded)].join("; ") })
        end

        # What the local branch holds beyond the commit carried, named so nobody has to look.
        def leftover(boarded)
          waiting = read("log", "--format=%h %s", "#{boarded}..#{@branch}").lines.map(&:strip)
          return [] if waiting.empty?

          ["#{waiting.size} commit(s) landed meanwhile and were not pushed (board again): #{waiting.first(5).join(" | ")}"]
        end

        def push(boarded, attempt = 1)
          before = read("rev-parse", tracking)
          pushed = Bench.new(@git, @checkout, branch: @branch, remote: @remote, config: @config)
                        .push(boarded, tracking)
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
