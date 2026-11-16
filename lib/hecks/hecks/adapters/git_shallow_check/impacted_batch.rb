# frozen_string_literal: true

require "json"
require_relative "../git_rehearsal/impacted/spec_run"
require_relative "../console_capture"

module Hecks
  module Adapters
    class GitShallowCheck
      # Runs several spec files in one launcher call (one library boot), each file in a process of
      # its own, and names the failing files and examples when the call is refused.
      #
      # The call takes no heavy-job place of its own: the landing's shallow check holds one and the
      # launcher inherits `HECKS_HEAVY_SLOT_HELD` from it.
      module ImpactedBatch
        # The launcher command for several files.
        LAUNCHER = %w[exe/hecks test_suite_run.run_spec_files!].freeze

        # The most spec files one call takes: below the world's local `spec_files_limit`, and the
        # most a budget can be overrun by, since the budget is read between calls.
        SIZE = 4

        JSON_FROM = GitRehearsal::Impacted::SpecRun::JSON_FROM
        FAILED = GitRehearsal::Impacted::SpecRun::FAILED
        NO_FAILURES = /\b0 failures\b/
        FAILED_FILES = /^failed: (.*) \(\d+ of \d+ files\)$/

        module_function

        # @param shell [#capture] runs the launcher: `capture(*argv, env:, chdir:)`
        # @param checkout [String] the branch's worktree
        # @param specs [Array<String>] the spec files of the call
        # @return [void]
        # @raise [ConsoleCapture::Failure] naming each failing file and example
        def call(shell, checkout, specs)
          result = shell.capture(*LAUNCHER, "files.value=#{specs.join(" ")}", "isolation.value=process", "--wait",
                                 env: {}, chdir: checkout)
          report = said(result)
          return if result.ok? && report.match?(NO_FAILURES) && !report.match?(FAILED_FILES)

          raise ConsoleCapture::Failure, "impacted specs red: #{named(report, specs, result)}"
        end

        # @param result [Shell::Result] the launcher's answer
        # @return [String] the run's report, or its refusal
        def said(result)
          json = result.out[JSON_FROM]
          state = json ? JSON.parse(json)["state"] || {} : {}
          state.fetch("report") { state["refusal"] }.to_s
        rescue JSON::ParserError
          ""
        end

        # @return [String] each failing example, else each failing file, else the call's files
        def named(report, specs, result)
          examples = report.scan(FAILED).map { |where, what| [where, what].compact.join(" # ") }
          failing = examples.empty? ? report[FAILED_FILES, 1].to_s.split : examples
          failing = ["exit #{result.exit_code} in #{specs.join(" ")}"] if failing.empty?
          "failing spec: #{failing.join(", ")}"
        end
      end
    end
  end
end
