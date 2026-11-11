# frozen_string_literal: true

require "json"
require "hecks/check_conclusion"
require_relative "../console_capture"

module Hecks
  module Adapters
    class CiRuns
      # The failed jobs of one CI run, each read on its own through `gh`: its name, the steps that
      # failed and its own failed log. It reports facts about each job and decides nothing about the
      # pull request; one job's setup failure is never read as another job's.
      class FailedJobs
        # The spec files an rspec failure summary names: `rspec ./spec/x_spec.rb:12 # description`.
        SPEC_LINE = %r{rspec (?:\./)?(\S+?_spec\.rb)}

        # What a log that reached the specs holds: a summary line, a failed example or a load error.
        SPEC_RAN = %r{Failure/Error|\d+ examples?, \d+ failures?|rspec (?:\./)?\S+_spec\.rb|error occurred while loading}

        # One failed job: `id`, `name`, the failed `steps` (as `job/step` names) and its `log`.
        Job = Struct.new(:id, :name, :steps, :log) do
          # @return [Boolean] whether the job reached the specs, so its failure is the code's
          def spec? = log.match?(SPEC_RAN)

          # @return [Array<String>] the spec files the job's log names
          def specs = log.scan(SPEC_LINE).flatten.uniq
        end

        # @param runner [#call] takes `(argv, chdir:)` and answers `[ok, output]`
        # @param checkout [String] the directory `gh` runs in
        def initialize(runner, checkout)
          @runner = runner
          @checkout = checkout
        end

        # @param run [String] the CI run's id
        # @return [Array<Job>] the jobs of the run that did not succeed, empty when `gh` names none
        # @raise [ConsoleCapture::Failure] when `gh` cannot list the jobs
        def read(run)
          listed = JSON.parse(call(["gh", "run", "view", run, "--json", "jobs"], raise_on_fail: true))
          failed = listed.fetch("jobs", []).reject { |job| Hecks::CheckConclusion.clean?(job["conclusion"]) }
          failed.map { |job| job_of(run, job) }
        end

        private

        def job_of(run, job)
          log = call(["gh", "run", "view", run, "--job", job["databaseId"].to_s, "--log-failed"])
          Job.new(job["databaseId"], job["name"], failed_steps(job), log)
        end

        def failed_steps(job)
          bad = Array(job["steps"]).reject { |step| Hecks::CheckConclusion.clean?(step["conclusion"]) }
          bad.map { |step| "#{job["name"]}/#{step["name"]}" }.then { |names| names.empty? ? [job["name"]] : names }
        end

        def call(argv, raise_on_fail: false)
          ok, output = @runner.call(argv, chdir: @checkout)
          raise ConsoleCapture::Failure, "gh #{argv[1, 2].join(" ")} failed: #{output.to_s.strip}" if !ok && raise_on_fail

          ok ? output.to_s : ""
        end
      end
    end
  end
end
