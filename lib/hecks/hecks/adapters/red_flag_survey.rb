# frozen_string_literal: true

require "json"
require_relative "console_capture"
require_relative "main_integration/command_runner"

module Hecks
  module Adapters
    # Reads the newest CI run of a push to main through `gh` and says whether main is red, green or
    # still being judged.
    class RedFlagSurvey
      # The workflow whose run is read.
      WORKFLOW = "CI"

      # Job conclusions that are not a failure.
      CLEAN = %w[success skipped neutral].freeze

      # @param runner [#call, nil] takes `(argv, chdir:)` and answers `[ok, output]`
      # @param checkout [String] a directory in the repository
      def initialize(runner:, checkout:)
        @runner = runner || MainIntegration::CommandRunner.new
        @checkout = checkout
      end

      # @return [Hash] `verdict:` (`:red`, `:green` or `:running`), `commit:` and `detail:` in the
      #   words `RedFlagging` reads a run id and failed jobs from
      # @raise [ConsoleCapture::Failure] when `gh` cannot be read
      def latest
        run = gh("run", "list", "--workflow", WORKFLOW, "--branch", "main", "--event", "push", "--limit", "1",
                 "--json", "databaseId,status,conclusion,headSha").first
        return { verdict: :running, commit: "", detail: "no #{WORKFLOW} run of main yet" } unless run
        return running(run) unless run["status"] == "completed"

        judged(run)
      end

      private

      def running(run) = { verdict: :running, commit: run["headSha"], detail: "run #{run["databaseId"]} is #{run["status"]}" }

      def judged(run)
        id = run["databaseId"]
        return { verdict: :green, commit: run["headSha"], detail: "run #{id} passed" } if run["conclusion"] == "success"

        said = "#{run["headSha"][0, 10]}: run #{id} #{run["conclusion"]}; failed jobs: #{failed(id)}"
        { verdict: :red, commit: run["headSha"], detail: said }
      end

      def failed(id)
        jobs = gh("run", "view", id.to_s, "--json", "jobs").fetch("jobs", [])
        names = jobs.reject { |job| CLEAN.include?(job["conclusion"].to_s) }.map { |job| job["name"] }
        names.empty? ? "none named" : names.join(", ")
      end

      def gh(*args)
        ok, output = @runner.call(["gh", *args], chdir: @checkout)
        raise ConsoleCapture::Failure, "gh #{args.first(2).join(" ")} failed: #{output.to_s.strip}" unless ok

        JSON.parse(output)
      rescue JSON::ParserError
        raise ConsoleCapture::Failure, "gh #{args.first(2).join(" ")} answered no JSON"
      end
    end
  end
end
