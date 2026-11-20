# frozen_string_literal: true

require_relative "../console_capture"
require_relative "../git_shallow_check/impacted_batch"
require_relative "impacted_check"

module Hecks
  module Adapters
    class MainIntegration
      # Runs the failing examples of a red train in a clean copy, one launcher call each, as
      # {SpecProbe} runs whole files. CI names an example by its file and line
      # (`spec/x_spec.rb:12`), and a line moves from one landing to the next, so the example is
      # run by the description that line holds at the train's head. A copy that holds no such file
      # or no such example runs nothing and is green: the example did not exist there. It answers
      # by returning when every example passes and by raising `ConsoleCapture::Failure` when one
      # does not.
      class ExampleProbe
        # The launcher command for one example of one file.
        LAUNCHER = %w[exe/hecks test_suite_run.run_spec_example!].freeze

        # The description an example's first line declares.
        DESCRIBED = /^\s*(?:it|specify|example|scenario)\s*\(?\s*(["'])(.+?)\1/

        # What a run that failed an example says in its report.
        FAILURES = /\b[1-9]\d* failures?\b/

        # How many of a failed run's last characters the failure keeps.
        KEPT = 600

        # @param repository [Repository] the repository the train's head is read in
        # @param landed [String] the train's head, where CI named the examples
        # @param shell [#capture] runs the launcher: `capture(*argv, env:, chdir:)`
        def initialize(repository, landed, shell: ImpactedCheck::Launched.new)
          @repository = repository
          @landed = landed
          @shell = shell
        end

        # @param directory [String] the clean copy
        # @param examples [Array<String>] the failing examples, each `spec/x_spec.rb:12`
        # @return [void]
        # @raise [ConsoleCapture::Failure] naming the first example that is red in the copy
        def call(directory, examples)
          examples.each do |example|
            file, line = example.split(":", 2)
            run(directory, file, description(file, line.to_i)) if File.exist?(File.join(directory, file))
          end
        end

        # @param file [String] a spec file
        # @param line [Integer] the line CI named, 1 the first
        # @return [String] the description the line declares at the train's head; a single space,
        #   which matches every example of the file, when the line declares none
        def description(file, line)
          held = line.positive? ? @repository.file_at(@landed, file).to_s.lines[line - 1].to_s : ""
          held[DESCRIBED, 2] || " "
        end

        private

        def run(directory, file, described)
          argv = [*LAUNCHER, "file.value=#{file}", "example.value=#{described}", "--wait"]
          result = @shell.capture(*argv, env: {}, chdir: directory)
          said = [GitShallowCheck::ImpactedBatch.said(result), result.err].join("\n").strip
          return if result.ok? && !said.match?(FAILURES)

          raise ConsoleCapture::Failure, "failing spec: #{file}\n  1) #{described.strip}\n#{said[-KEPT..] || said}"
        end
      end
    end
  end
end
