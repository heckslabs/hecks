# frozen_string_literal: true

require_relative "shell"
require_relative "console_capture"

module Hecks
  module Adapters
    # The `Gate` port's adapter: asks a checkout to judge itself, by running that checkout's own
    # launcher there. What the gate holds is the checkout's business (its `quick` stage); delivery
    # only learns whether it passed and, when it did not, the end of what it printed (ADR 0205).
    #
    # It is also the one place the command line is written: a landing, a landing train and a
    # verification of main each take it from here.
    class CheckoutGate
      # The launcher, as a checkout holds it.
      LAUNCHER = "exe/hecks"

      # What the launcher is asked: the seconds-long checks, waited for.
      ARGUMENTS = %w[gate_run.gate! stage=quick --wait].freeze

      # The whole command line, run in the checkout.
      COMMAND = [LAUNCHER, *ARGUMENTS].freeze

      # What a completed gate run prints.
      COMPLETED = /"status":\s*"completed"/

      # How many of the gate's last lines a refusal carries.
      TAIL = 5

      # What a gate run said and whether it passed.
      #
      # @!attribute [r] directory
      #   @return [String] the checkout that was judged
      # @!attribute [r] out
      #   @return [String] what the gate printed, its standard error after its standard output
      # @!attribute [r] green
      #   @return [Boolean] whether the launcher ended well and reported a completed run
      Verdict = Struct.new(:directory, :out, :green) do
        # @return [Boolean] whether the gate passed
        def green? = green

        # @param count [Integer] how many lines
        # @return [String] the last lines of what the gate printed
        def tail(count = TAIL) = last_lines(count).join.strip

        private

        def last_lines(count) = out.lines.last(count)
      end

      # @param aggregate [Object, nil] unused
      # @param settings [Hash] unused
      # @param root [String, nil] unused
      # @param shell [#capture, nil] runs the command; a spec stands in
      def initialize(aggregate: nil, settings: {}, root: nil, shell: nil)
        @shell = shell || Shell.new
      end

      # Judges the checkout a shipment names.
      #
      # @param held [Hash] the `Shipment` record: its `checkout`, the directory to judge
      # @return [Hash{Symbol => Hash}] `report:` saying the gate is green and where
      # @raise [ConsoleCapture::Failure] when no checkout is named, or its gate is red
      def judge(**held)
        directory = plain(held[:checkout]).to_s
        raise ConsoleCapture::Failure, "no checkout to judge: the shipment names none" if directory.empty?

        verdict = verdict(directory)
        raise ConsoleCapture::Failure, "gate red: the gate failed in #{directory}: #{verdict.tail}" unless verdict.green?

        { report: { value: "gate green in #{directory}" } }
      end

      # Runs a checkout's gate and answers what it said.
      #
      # @param directory [String] the checkout to judge
      # @return [Verdict]
      def verdict(directory)
        result = @shell.capture(*COMMAND, chdir: directory)
        Verdict.new(directory, "#{result.out}#{result.err}", result.ok? && result.out.match?(COMPLETED))
      end

      private

      def plain(argument) = argument.is_a?(Hash) ? argument[:value] : argument
    end
  end
end
