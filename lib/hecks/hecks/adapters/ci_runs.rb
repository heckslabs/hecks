# frozen_string_literal: true

require "json"
require_relative "console_capture"
require_relative "main_integration/command_runner"

module Hecks
  module Adapters
    # The `CiRuns` port's adapter for `Integration.Observe`: reads, through `gh`, the CI run of a
    # push of main at a landed commit. It answers `running` while there is no run yet or it has not
    # completed, `passed` when it succeeded, and `failed` with the jobs that did not succeed.
    class CiRuns
      # The workflow whose run is read, as GitHub names it.
      WORKFLOW = "CI"

      # Job conclusions that are not a failure.
      CLEAN = %w[success skipped neutral].freeze

      class << self
        # @return [#call, nil] takes `(argv, chdir:)` and answers `[ok, output]`; the command
        #   runner when nil. A spec replaces it with a fake GitHub.
        attr_accessor :runner
      end

      # @param aggregate [Object, nil] unused
      # @param settings [Hash] unused
      # @param root [String, nil] unused
      def initialize(aggregate: nil, settings: {}, root: nil); end

      # @param held [Hash] the `Integration` record: `landed` and `checkout`
      # @return [Hash{Symbol => Hash}] `outcome:` (`running`, `passed` or `failed`) and `report:`
      # @raise [ConsoleCapture::Failure] when `gh` cannot be read
      def watch(**held)
        landed = plain(held[:landed]).to_s
        @checkout = plain(held[:checkout]) || Dir.pwd
        run = latest_run(landed)
        return answer("running", "#{landed[0, 10]}: no #{WORKFLOW} run yet") unless run
        return answer("running", "#{landed[0, 10]}: #{WORKFLOW} run #{run["databaseId"]} is #{run["status"]}") unless
          run["status"] == "completed"

        verdict(landed, run)
      end

      private

      def latest_run(landed)
        gh("run", "list", "--workflow", WORKFLOW, "--branch", "main", "--event", "push", "--commit", landed,
           "--json", "databaseId,status,conclusion", "--limit", "1").first
      end

      def verdict(landed, run)
        id = run["databaseId"]
        return answer("passed", "#{landed[0, 10]}: #{WORKFLOW} run #{id} passed") if run["conclusion"] == "success"

        answer("failed", "#{landed[0, 10]}: #{WORKFLOW} run #{id} #{run["conclusion"]}; failed jobs: #{failed_jobs(id)}")
      end

      def failed_jobs(id)
        jobs = gh("run", "view", id.to_s, "--json", "jobs").fetch("jobs", [])
        names = jobs.reject { |job| CLEAN.include?(job["conclusion"].to_s) }.map { |job| job["name"] }
        names.empty? ? "none named" : names.join(", ")
      end

      def gh(*args)
        ok, output = runner.call(["gh", *args], chdir: @checkout)
        raise ConsoleCapture::Failure, "gh #{args.first(2).join(" ")} failed: #{output.to_s.strip}" unless ok

        JSON.parse(output)
      rescue JSON::ParserError
        raise ConsoleCapture::Failure, "gh #{args.first(2).join(" ")} answered no JSON"
      end

      def answer(outcome, report) = { outcome: { value: outcome }, report: { value: report } }

      def runner = self.class.runner || MainIntegration::CommandRunner.new

      def plain(argument) = argument.is_a?(Hash) ? argument[:value] : argument
    end
  end
end
