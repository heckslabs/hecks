# frozen_string_literal: true

require_relative "reading"

module Hecks
  module Adapters
    class GitTrain
      # One boarding's work once it holds the line: fetch the remote's branch, then either find
      # the boarded commit already there or push the local branch.
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
        # @param hook_env [Hash{String => String}] variables the repository's pre-push hook reads
        def initialize(git, checkout, branch:, remote:, hook_env: {})
          @git = git
          @checkout = checkout
          @branch = branch
          @remote = remote
          @hook_env = hook_env
        end

        # @return [String] the commit the local branch names now
        # @raise [ConsoleCapture::Failure] when there is no such branch
        def local_head = read("rev-parse", "--verify", "refs/heads/#{@branch}^{commit}")

        # Carries the boarded commit: finds it already on the remote, or pushes the local branch.
        #
        # @param boarded [String] the commit the local branch named at boarding
        # @return [Hash{Symbol => Hash}] the answer `GitTrain#carry` describes
        # @raise [ConsoleCapture::Failure] when the branches conflict or the push is refused
        def carry(boarded)
          fetch
          return carried(boarded) if ancestor?(boarded, tracking)

          push(boarded)
        end

        private

        def push(boarded, attempt = 1)
          before = read("rev-parse", tracking)
          pushed = Bench.new(@git, @checkout, branch: @branch, remote: @remote, hook_env: @hook_env)
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
