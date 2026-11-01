# frozen_string_literal: true

require "json"

module Hecks
  module Adapters
    class GitRehearsal
      class Impacted
        # Runs one spec file through the launcher and reads how it ended.
        class SpecRun
          # How one spec file ended.
          #
          # @!attribute [r] spec
          #   @return [String] the spec file
          # @!attribute [r] passed
          #   @return [Boolean] whether every example passed
          # @!attribute [r] failures
          #   @return [Array<String>] the failing examples, `./spec/a_spec.rb:12 # description`
          Outcome = Struct.new(:spec, :passed, :failures) do
            # @return [String] the spec and its first failing example, for the report
            def line = "failing spec: #{failures.first || spec}"
          end

          LAUNCHER = %w[exe/hecks test_suite_run.run_spec_example!].freeze
          GREEN = /\b\d+ examples?, 0 failures/
          JSON_FROM = /^\{.*\z/m
          FAILED = %r{^rspec (\./\S+)(?: # (.*))?$}

          # @param capture [#call] given a command and `env:`, runs it in a directory and returns a
          #   `Shell::Result`; the directory is the first argument
          def initialize(capture)
            @capture = capture
          end

          # @param directory [String] the copy to run in
          # @param spec [String] the spec file, relative to it
          # @param io [Boolean] whether the file's `:io` examples are to run
          # @return [Outcome]
          def call(directory, spec, io: false)
            env = io ? { "CI" => "true" } : {}
            result = @capture.call(directory, *LAUNCHER, "file.value=#{spec}", "example.value= ", "--wait", env: env)
            report = report(result)
            Outcome.new(spec, result.ok? && GREEN.match?(report), failures(report, result))
          end

          private

          def report(result)
            json = result.out[JSON_FROM]
            json ? said(JSON.parse(json)) : ""
          rescue JSON::ParserError
            ""
          end

          # A red run is refused, with the output in the refusal and none in the report.
          def said(answer) = (answer.dig("state", "report") || answer.dig("state", "refusal")).to_s

          def failures(report, result)
            listed = report.scan(FAILED).map { |where, what| [where, what].compact.join(" # ") }
            return listed unless listed.empty?

            report.empty? ? ["exit #{result.exit_code}: #{printed(result.err).last}"] : []
          end

          def printed(text) = text.lines.map(&:strip).reject(&:empty?)
        end
      end
    end
  end
end
