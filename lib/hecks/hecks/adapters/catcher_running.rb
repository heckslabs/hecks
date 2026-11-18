# frozen_string_literal: true

require "hecks/tools/run"
require_relative "console_capture"

module Hecks
  module Adapters
    # The `Running` port's adapter for `CatcherCare`: requests the Catcher's drain and then its
    # detection, as `Operation.run!` does, through `Tools::Run` against the Catcher's directory.
    # It only requests them: the Catcher chains their outcomes itself, so an answer means both were
    # requested, and a refusal of either is refused by name.
    class CatcherRunning
      # The Catcher's directory, beside this one in `lib/hecks`.
      DOMAIN = File.expand_path("../../catcher", __dir__)

      # The verbs requested, in order, each with the prefix of its run key.
      VERBS = { "drain.request!" => "drain", "detection.request!" => "detect" }.freeze

      # @param registry [Object, nil] unused
      # @param aggregate [Object, nil] unused
      # @param settings [Hash] `runner:` a stand-in called with the argument list and answering text
      # @param root [String, nil] unused
      def initialize(registry: nil, aggregate: nil, settings: {}, root: nil)
        @runner = settings[:runner] || method(:run)
      end

      # @param held [Hash] the `CatcherCare` record: `run`
      # @return [Hash{Symbol => Hash}] `outcome`, the verbs requested
      # @raise [ConsoleCapture::Failure] when the Catcher refuses a request
      def run_catcher(**held)
        key = plain(held[:run])
        VERBS.each { |verb, prefix| @runner.call([DOMAIN, verb, "run.value=#{prefix}-#{key}"]) }
        { outcome: { value: "requested #{VERBS.keys.join(" then ")}" } }
      end

      private

      def run(argv)
        ConsoleCapture.answer_apart { Tools::Run.call(argv, program: "hecks run") }
      end

      def plain(argument) = argument.is_a?(Hash) ? argument[:value] : argument
    end
  end
end
