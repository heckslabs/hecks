# frozen_string_literal: true

require_relative "../console_capture"
require_relative "filing"

module Hecks
  module Adapters
    class CandidateGating
      # The clearing of a red candidate, with nothing lost: local main's tip is kept on a
      # `rejected/<sha>` branch (the candidate's commits and whatever landed after them), local
      # main is reset to the remote's, one `red-<cause>` Work item is filed per failing cause, and
      # the authors and branches the candidate carried are named for the coders. The remote's
      # candidate ref is left as it is: the next boarding moves it.
      class Rejection
        # The lead of the branch that keeps a rejected candidate's commits.
        BRANCH = "rejected/"

        # What the candidate carried: the commits, their authors and the branches merged.
        Carried = Struct.new(:commits, :authors, :branches, keyword_init: true)

        # @param parts [Hash] `repository:`, `marker:`, `ci:` and `checkout:`
        # @param registry [Runtime::Registry, nil] the booted registry the Work items are filed in
        def initialize(parts, registry: nil)
          @repository = parts.fetch(:repository)
          @marker = parts.fetch(:marker)
          @ci = parts.fetch(:ci)
          @checkout = parts.fetch(:checkout)
          @filing = Filing.new(registry, remote_main: @repository.remote_main)
        end

        # @return [Hash{Symbol => Hash}] `outcome:` `rejected`, `sha:`, `branch:`, `work_items:`,
        #   `authors:`, `report:`
        # @raise [ConsoleCapture::Failure] when there is no candidate, it is not red, or local
        #   main is not clean
        def answer
          candidate = @marker.read or refuse!("no candidate is recorded for #{@checkout}")
          @repository.fetch
          settled!(candidate)
          red = red!(candidate)
          worktree = clean_main!
          keep(red, worktree)
        end

        private

        def settled!(candidate)
          case candidate["state"].to_s
          when "promoted" then refuse!("candidate #{short(candidate)} was promoted: nothing to reject")
          when "rejected" then refuse!("candidate #{short(candidate)} was rejected already; it is kept on #{candidate["branch"]}")
          end
        end

        # A candidate recorded red is rejected; one not yet observed is read now.
        def red!(candidate)
          return candidate if candidate["state"] == "red"

          run = @ci.run_of(candidate["sha"])
          refuse!("candidate #{short(candidate)} is not red: #{run || "no CI run yet"}") unless run&.verdict == :failed

          @marker.note!("red", ci_run: run.id, jobs: run.jobs)
        end

        # The worktree holding main, which must be clean, or nil when no worktree holds it.
        def clean_main!
          worktree = @repository.main_worktree
          return worktree if worktree.nil? || @repository.clean?(worktree)

          refuse!("local main is not clean in #{worktree}: commit or discard its changes before rejecting")
        end

        def keep(candidate, worktree)
          tip = @repository.commit("main") or refuse!("#{@checkout} has no main branch")
          base = @repository.commit(@repository.remote_main) or refuse!("#{@repository.remote_main} is unknown here")
          branch = keep_branch(candidate, tip)
          carried = carried(base, tip)
          reset_main(base, tip, worktree)
          filed = @filing.file(candidate, branch, carried)
          answer_with(@marker.note!("rejected", branch: branch, work_items: filed.join(", ")), branch, carried, filed)
        end

        def carried(base, tip)
          Carried.new(commits: @repository.commits(base, tip).size, authors: @repository.authors(base, tip),
                      branches: @repository.branches(base, tip))
        end

        # The branch keeps main's tip, a superset of the candidate; one already there at another
        # commit is never moved.
        def keep_branch(candidate, tip)
          branch = "#{BRANCH}#{candidate["sha"].to_s[0, 12]}"
          held = @repository.commit(branch)
          refuse!("#{branch} already exists at #{held[0, 10]}, not at main's tip #{tip[0, 10]}") if held && held != tip
          @repository.read("branch", branch, tip) unless held
          branch
        end

        def reset_main(base, tip, worktree)
          return if base == tip
          return @repository.read("update-ref", "refs/heads/main", base, tip) unless worktree

          @repository.read("reset", "-q", "--hard", base, dir: worktree)
        end

        def answer_with(candidate, branch, carried, filed)
          { outcome: { value: "rejected" }, sha: { value: candidate["sha"].to_s }, branch: { value: branch },
            work_items: { value: filed.join(", ") }, authors: { value: carried.authors.join(", ") },
            report: { value: report(candidate, branch, carried, filed) }, checkout: { value: @checkout } }
        end

        def report(candidate, branch, carried, filed)
          "candidate #{short(candidate)} rejected: #{carried.commits} commit(s) kept on #{branch}; local main reset " \
            "to #{@repository.remote_main}; Work items #{filed.empty? ? "none filed" : filed.join(", ")}; " \
            "coders: #{carried.authors.join(", ")}; branches: #{carried.branches.join(", ")}"
        end

        def short(candidate) = candidate["sha"].to_s[0, 10]

        def refuse!(why) = raise(ConsoleCapture::Failure, why)
      end
    end
  end
end
