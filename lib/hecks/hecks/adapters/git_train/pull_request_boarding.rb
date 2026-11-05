# frozen_string_literal: true

require_relative "reading"
require_relative "bench"

module Hecks
  module Adapters
    class GitTrain
      # One boarding of main as a pull request. The boarded commit goes to its own branch on the
      # remote, a PR into main is opened for it, and auto-merge is turned on so GitHub merges it
      # once the required checks pass. The train never moves main itself, and the candidate ref is
      # not used: the PR is the gate.
      #
      # A commit not built on the remote's main is refused by Bench before anything is pushed, and
      # a commit main already carries is answered `carried` without a PR.
      class PullRequestBoarding
        include Reading

        # The branch a boarded commit is pushed to. Named by the commit, so each boarding is its own
        # branch and a boarding that is retried finds its branch already there.
        def self.branch_for(commit) = "train/main-#{commit[0, 12]}"

        # @param git [Git] the adapter every git call goes through
        # @param checkout [String] the repository's top level
        # @param remote [String] the remote the branch is pushed to and the PR opened against
        # @param config [Array<String>] `-c name=value` words for the push, read by the hook
        # @param runner [#call] takes `(argv, chdir:)` and answers `[ok, output]` for `gh`
        def initialize(git, checkout, remote:, config: [], runner:)
          @git = git
          @checkout = checkout
          @remote = remote
          @config = config
          @runner = runner
        end

        # @param boarded [String] the commit to carry, which local main must still name
        # @return [Hash{Symbol => Hash}] `outcome:` `queued` (a PR is open and set to auto-merge) or
        #   `carried` (main already carries the commit), with `boarded:` and `report:`
        # @raise [ConsoleCapture::Failure] when main moved since boarding, the commit is not built on
        #   the remote's main, the push is refused, or `gh` cannot open or auto-merge the PR
        def carry(boarded)
          fetch
          moved_since!(boarded)
          return carried(boarded) if ancestor?(boarded, tracking)

          branch = self.class.branch_for(boarded)
          Bench.new(@git, @checkout, branch: branch, remote: @remote, config: @config).push(boarded, tracking)
          url = open_pr(branch, boarded)
          enable_auto_merge(branch)
          queued(boarded, branch, url)
        end

        private

        def fetch = read("fetch", "--quiet", @remote, "+refs/heads/main:refs/remotes/#{tracking}")

        def tracking = "#{@remote}/main"

        def moved_since!(boarded)
          now = read("rev-parse", "--verify", "refs/heads/main^{commit}")
          return if now == boarded

          raise ConsoleCapture::Failure, "main moved since boarding (boarded #{short(boarded)}, now #{short(now)}): board again"
        end

        def open_pr(branch, boarded)
          ok, output = @runner.call(
            ["gh", "pr", "create", "--base", "main", "--head", branch,
             "--title", "Train: main at #{short(boarded)}",
             "--body", "Boarded by the push train. Merges once the required checks pass."],
            chdir: @checkout
          )
          raise ConsoleCapture::Failure, "could not open a PR for #{branch}: #{output.to_s.strip}" unless ok

          output.to_s.strip.lines.last.to_s.strip
        end

        def enable_auto_merge(branch)
          ok, output = @runner.call(["gh", "pr", "merge", branch, "--auto", "--squash", "--delete-branch"], chdir: @checkout)
          raise ConsoleCapture::Failure, "could not set #{branch} to auto-merge: #{output.to_s.strip}" unless ok
        end

        def queued(boarded, branch, url)
          { outcome: { value: "queued" }, checkout: { value: @checkout }, boarded: { value: boarded },
            report: { value: "queued #{short(boarded)} as #{url} on #{branch}; auto-merge on, merges when checks pass" } }
        end

        def carried(boarded)
          { outcome: { value: "carried" }, checkout: { value: @checkout }, boarded: { value: boarded },
            report: { value: "#{short(boarded)} is already on #{tracking}: an earlier push carried it" } }
        end
      end
    end
  end
end
