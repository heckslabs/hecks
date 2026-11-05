# frozen_string_literal: true

require "json"
require_relative "reading"
require_relative "bench"

module Hecks
  module Adapters
    class GitTrain
      # One boarding of main as a pull request. The boarded commit goes to its own branch on the
      # remote, a PR into main is opened for it, and auto-merge is turned on so GitHub merges it
      # once the required checks pass. The train never moves main itself.
      #
      # The boarding is `queued` until the PR merges. `PullRequestBoarding::Observation` reads that
      # PR; when it has merged, the merge commit is the pushed commit, and the saga records the push
      # from it, which is what refreshes the launcher and announces the deploy.
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
        def initialize(git, checkout, remote:, runner:, config: [])
          @git = git
          @checkout = checkout
          @remote = remote
          @config = config
          @runner = runner
        end

        # @param boarded [String] the commit to carry, which local main must still name
        # @return [Hash{Symbol => Hash}] `outcome:` `queued` (a PR is open and set to auto-merge) or
        #   `carried` (main already carries the commit), with `boarded:` and `report:`
        # @raise [ConsoleCapture::Failure] when main moved since boarding, the commit is not
        #   built on the remote's main, the push is refused, or `gh` cannot open or auto-merge
        #   the PR
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

        # Reads a queued boarding's PR. Open, it answers `open` and nothing else; merged, it answers
        # `merged` with the merge commit as the pushed commit.
        class Observation
          # @param runner [#call] takes `(argv, chdir:)` and answers `[ok, output]` for `gh`
          # @param checkout [String] the repository's top level
          def initialize(runner, checkout)
            @runner = runner
            @checkout = checkout
          end

          # @param boarded [String] the commit the boarding queued
          # @return [Hash{Symbol => Hash}] `outcome:` `merged` (with `pushed:`) or `open`,
          #   and `report:`
          # @raise [ConsoleCapture::Failure] when `gh` cannot read the PR, or a merged PR names
          #   no commit
          def answer(boarded)
            branch = PullRequestBoarding.branch_for(boarded)
            ok, output = @runner.call(["gh", "pr", "view", branch, "--json", "state,mergeCommit"], chdir: @checkout)
            raise ConsoleCapture::Failure, "could not read the PR for #{branch}: #{output.to_s.strip}" unless ok

            pr = JSON.parse(output.to_s)
            return open_answer(branch, pr) unless pr["state"] == "MERGED"

            merged(branch, pr.dig("mergeCommit", "oid"))
          end

          private

          def open_answer(branch, view)
            { outcome: { value: "open" }, report: { value: "#{branch} is #{view["state"].to_s.downcase}; not merged yet" } }
          end

          def merged(branch, merge)
            raise ConsoleCapture::Failure, "#{branch} merged but gh named no merge commit" if merge.to_s.empty?

            { outcome: { value: "merged" }, pushed: { value: merge },
              report: { value: "#{branch} merged as #{merge[0, 9]}" } }
          end
        end

        private

        def fetch = read("fetch", "--quiet", @remote, "+refs/heads/main:refs/remotes/#{tracking}")

        def tracking = "#{@remote}/main"

        def moved_since!(boarded)
          now = read("rev-parse", "--verify", "refs/heads/main^{commit}")
          return if now == boarded

          raise ConsoleCapture::Failure, "main moved since boarding (boarded #{short(boarded)}, now #{short(now)}): board again"
        end

        # Opens the PR, or finds the one a retried boarding already opened.
        def open_pr(branch, boarded)
          ok, output = @runner.call(
            ["gh", "pr", "create", "--base", "main", "--head", branch,
             "--title", "Train: main at #{short(boarded)}",
             "--body", "Boarded by the push train. Merges once the required checks pass."],
            chdir: @checkout
          )
          return url_from(output) if ok

          existing(branch) || raise(ConsoleCapture::Failure, "could not open a PR for #{branch}: #{output.to_s.strip}")
        end

        # `gh pr create` prints the PR's URL as its last line.
        def url_from(output)
          lines = output.to_s.strip.lines
          lines.last.to_s.strip
        end

        def existing(branch)
          ok, output = @runner.call(["gh", "pr", "view", branch, "--json", "url", "--jq", ".url"], chdir: @checkout)
          ok ? output.to_s.strip : nil
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
