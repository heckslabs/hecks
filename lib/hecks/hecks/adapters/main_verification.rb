# frozen_string_literal: true

require_relative "console_capture"
require_relative "main_integration"
require_relative "main_integration/repository"
require_relative "main_integration/checks"
require_relative "main_integration/command_runner"

module Hecks
  module Adapters
    # The `MainVerifying` port's adapter for `Integration.Verify`: checks a landed commit in a
    # clean detached copy of it, holding no local Hecks files, by running every check `Checks`
    # names there. A commit other than the head of local main is answered `superseded` without a
    # check: the run for the head verifies both. A check that fails refuses the
    # verification, naming each failing check and what it printed last.
    class MainVerification
      # How much of a failing check's output a refusal keeps.
      TAIL = 400

      class << self
        # @return [#call, nil] takes `(argv, chdir:)` and answers `[ok, output]`; the command
        #   runner when nil. A spec replaces it so no check has to run.
        attr_accessor :runner
      end

      # @param aggregate [Object, nil] unused
      # @param settings [Hash] unused
      # @param root [String, nil] unused
      def initialize(aggregate: nil, settings: {}, root: nil)
        @failures = []
      end

      # @param held [Hash] the `Integration` record: `landed` and `checkout`
      # @return [Hash{Symbol => Hash}] `outcome:` (`verified` or `superseded`) and `report:`
      # @raise [ConsoleCapture::Failure] naming every check that failed
      def check(**held)
        landed = plain(held[:landed]).to_s
        repository = MainIntegration::Repository.new(plain(held[:checkout]) || Dir.pwd)
        head = repository.main
        return superseded(landed, head) unless head == landed

        passed = run_checks(repository, landed)
        answer("verified", "#{landed[0, 10]} verified: #{passed.join(", ")}")
      end

      private

      def run_checks(repository, landed)
        changed = repository.changed(repository.remote_main, landed)
        repository.clean_copy(landed) do |directory|
          checks = MainIntegration::Checks.new(directory, changed).all
          failed = checks.reject { |name, argv| record(name, argv, directory) }
          refuse!(landed) unless failed.empty?
          checks.map(&:first)
        end
      end

      def record(name, argv, directory)
        ok, output = runner.call(argv, chdir: directory)
        @failures << "#{name}: #{tail(output)}" unless ok
        ok
      end

      def refuse!(landed)
        raise ConsoleCapture::Failure, "#{landed[0, 10]} failed verification: #{@failures.join("; ")}"
      end

      def superseded(landed, head)
        answer("superseded", "#{landed[0, 10]} is not the head of main (#{head[0, 10]}); the run for the head carries it")
      end

      def answer(outcome, report) = { outcome: { value: outcome }, report: { value: report } }

      def tail(output)
        text = last_lines(output).split.join(" ")
        text.length > TAIL ? text[-TAIL..] : text
      end

      def last_lines(output)
        lines = output.to_s.strip.lines
        lines.last(3).join(" ")
      end

      def runner = self.class.runner || MainIntegration::CommandRunner.new

      def plain(argument) = argument.is_a?(Hash) ? argument[:value] : argument
    end
  end
end
