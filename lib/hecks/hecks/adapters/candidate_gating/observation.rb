# frozen_string_literal: true

require_relative "../console_capture"

module Hecks
  module Adapters
    class CandidateGating
      # One reading of the candidate against the truth: the remote's main (a candidate it holds
      # was promoted), the record (one rejected stays so), then GitHub's run of the candidate
      # (passed, failed or running). The record moves to what was read.
      class Observation
        # @param parts [Hash] `repository:`, `marker:`, `ci:` and `checkout:`
        def initialize(parts)
          @repository = parts.fetch(:repository)
          @marker = parts.fetch(:marker)
          @ci = parts.fetch(:ci)
          @checkout = parts.fetch(:checkout)
        end

        # @return [Hash{Symbol => Hash}] `outcome:` (`promoted`, `red`, `running` or `idle`),
        #   `sha:`, `ci_run:`, `jobs:`, `report:` and `checkout:`
        # @raise [ConsoleCapture::Failure] when the repository or `gh` cannot be read
        def answer
          candidate = @marker.read
          return idle("no candidate is recorded for #{@checkout}") unless candidate

          @repository.fetch
          promoted?(candidate) ? promoted(candidate) : judge(candidate)
        end

        private

        def promoted?(candidate)
          on_main = @repository.commit(@repository.remote_main)
          on_main && @repository.ancestor?(candidate["sha"], on_main)
        end

        def promoted(candidate)
          @marker.note!("promoted", via: "observed on #{@repository.remote_main}") unless candidate["state"] == "promoted"
          said("promoted", candidate, "candidate #{short(candidate)} is on #{@repository.remote_main}: promoted")
        end

        def judge(candidate)
          return idle("candidate #{short(candidate)} was rejected; its commits are on #{candidate["branch"]}") if
            candidate["state"] == "rejected"

          run = @ci.run_of(candidate["sha"])
          return said("running", candidate, "candidate #{short(candidate)}: no CI run yet") unless run

          verdict(candidate, run)
        end

        def verdict(candidate, run)
          case run.verdict
          when :passed then green(run)
          when :failed then red(run)
          else said("running", candidate, "candidate #{short(candidate)}: #{run}")
          end
        end

        def green(run)
          noted = @marker.note!("green", ci_run: run.id)
          said("running", noted, "candidate #{short(noted)} is green (#{run}): the candidate workflow promotes it; " \
                                 "candidate Candidate.promote! --confirm does it from here")
        end

        def red(run)
          noted = @marker.note!("red", ci_run: run.id, jobs: run.jobs)
          said("red", noted, "candidate #{short(noted)} is red (#{run}): candidate Candidate.reject! --confirm clears it")
        end

        def idle(report) = { outcome: { value: "idle" }, report: { value: report }, checkout: { value: @checkout } }

        # An empty fact is left out: an optional word of the record never takes an empty value.
        def said(outcome, candidate, report)
          facts = { sha: candidate["sha"], ci_run: candidate["ci_run"], jobs: candidate["jobs"] }
          { outcome: { value: outcome }, report: { value: report }, checkout: { value: @checkout },
            **facts.reject { |_, value| value.to_s.empty? }.transform_values { |value| { value: value.to_s } } }
        end

        def short(candidate) = candidate["sha"].to_s[0, 10]
      end
    end
  end
end
