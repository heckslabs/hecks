# frozen_string_literal: true

require_relative "../console_capture"
require_relative "../git_train/bench"
require_relative "../git_train/local_branch"
require_relative "../git_train/candidate_boarding"

module Hecks
  module Adapters
    class CandidateGating
      # The promotion made from here: the remote's main fast-forwarded onto the green candidate,
      # pushed by its own id from a detached bench so the pre-push hook checks exactly it, carrying
      # the promotion the hook reads. Never a force: a main that moved refuses the push, and a
      # candidate that is not green is refused before it.
      class Promotion
        # @param parts [Hash] `repository:`, `marker:`, `ci:` and `checkout:`
        def initialize(parts)
          @repository = parts.fetch(:repository)
          @marker = parts.fetch(:marker)
          @ci = parts.fetch(:ci)
          @checkout = parts.fetch(:checkout)
        end

        # @return [Hash{Symbol => Hash}] `outcome:` `promoted`, `sha:`, `ci_run:`, `report:`
        # @raise [ConsoleCapture::Failure] when there is no candidate, it is already settled, it is
        #   not green, or the push is refused
        def answer
          candidate = @marker.read or refuse!("no candidate is recorded for #{@checkout}")
          @repository.fetch
          return already(candidate) if @repository.ancestor?(candidate["sha"], @repository.commit(@repository.remote_main))

          green!(candidate)
          push(candidate["sha"])
        end

        private

        def already(candidate)
          @marker.note!("promoted", via: "observed on #{@repository.remote_main}") unless candidate["state"] == "promoted"
          answer_with(candidate, "candidate #{candidate["sha"][0, 10]} is already on #{@repository.remote_main}")
        end

        # A candidate recorded green is promoted; one not yet observed is read now.
        def green!(candidate)
          refuse!("candidate #{candidate["sha"][0, 10]} was rejected; nothing to promote") if candidate["state"] == "rejected"
          return if candidate["state"] == "green"

          run = @ci.run_of(candidate["sha"])
          refuse!("candidate #{candidate["sha"][0, 10]} is not green: #{run || "no CI run yet"}") unless run&.verdict == :passed

          @marker.note!("green", ci_run: run.id)
        end

        def push(sha)
          pushed = bench(sha).push(sha, @repository.remote_main)
          moved!(sha) if pushed == :moved

          local = GitTrain::LocalBranch.new(Git.new, @repository.top, "main").catch_up(sha)
          noted = @marker.note!("promoted", via: "Candidate.promote!")
          answer_with(noted, "promoted #{sha[0, 10]} onto #{@repository.remote_main}; #{local}")
        end

        def bench(sha)
          config = ["-c", "#{GitTrain::CandidateBoarding::PROMOTION}=#{sha}"]
          GitTrain::Bench.new(Git.new, @repository.top, branch: "main", remote: Repository::REMOTE, config: config)
        end

        def moved!(sha) = refuse!("#{@repository.remote_main} moved while #{sha[0, 10]} was promoted; observe and promote again")

        def answer_with(candidate, report)
          { outcome: { value: "promoted" }, sha: { value: candidate["sha"].to_s }, report: { value: report },
            checkout: { value: @checkout }, **(candidate["ci_run"] ? { ci_run: { value: candidate["ci_run"].to_s } } : {}) }
        end

        def refuse!(why) = raise(ConsoleCapture::Failure, why)
      end
    end
  end
end
