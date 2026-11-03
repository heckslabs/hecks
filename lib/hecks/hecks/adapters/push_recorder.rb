# frozen_string_literal: true

require_relative "shell"
require_relative "console_capture"

module Hecks
  module Adapters
    # The `PushRecords` port's adapter: records how a boarding of the push train ended in the
    # boarded checkout, by running that checkout's own launcher with `PushOutcome.record!`.
    #
    # The train runs in Memory in a checkout of its own; the boarded checkout's launcher boots that
    # checkout's domain, whose own overlay says where its records live, so the outcome lands in the
    # same journal as its landings. It records and decides nothing: the outcome is the run's
    # status, and a recording that fails is refused, which leaves the push as it was.
    class PushRecorder
      # The launcher, relative to the checkout's top directory.
      LAUNCHER = File.join("exe", "hecks")

      # The fields of the run recorded as they are held, beside the ones the outcome names.
      COPIED = %i[branch pushed commits].freeze

      # @param aggregate [Object, nil] unused
      # @param settings [Hash] `launcher:` the program to run instead of the checkout's own
      # @param root [String, nil] unused
      def initialize(aggregate: nil, settings: {}, root: nil)
        @launcher = settings[:launcher]
        @shell = Shell.new
      end

      # @param held [Hash] the `SendTrain` record: `run`, `status`, `checkout`, `branch`, `pushed`,
      #   `commits`, and `report` or `refusal`
      # @return [Hash{Symbol => Hash}] `report:` what the checkout's launcher said it recorded
      # @raise [ConsoleCapture::Failure] when no checkout is named or the launcher refuses
      def record_outcome(**held)
        top = top_of(plain(held[:checkout]))
        result = @shell.capture(*command(top), *arguments(held, top), "--wait", env: bundle(top), chdir: top)
        raise ConsoleCapture::Failure, "#{top} did not record the push: #{said(result)}" unless recorded?(result)

        { report: { value: "recorded the #{plain(held[:status])} push in #{top}" } }
      end

      private

      def top_of(checkout)
        raise ConsoleCapture::Failure, "the boarding names no checkout to record in" if checkout.to_s.empty?

        result = @shell.capture("git", "rev-parse", "--show-toplevel", chdir: checkout)
        raise ConsoleCapture::Failure, "#{checkout} is not a checkout: #{said(result)}" unless result.ok?

        result.out.strip
      end

      def command(top) = [@launcher || File.join(top, LAUNCHER)]

      # The checkout's launcher runs as it runs there: on its own Gemfile, not the train's this
      # process inherited, and with no environment overlay, which would win over the checkout's
      # own store.
      def bundle(top)
        gemfile = @launcher ? {} : { "BUNDLE_GEMFILE" => File.join(top, "Gemfile") }
        { "HECKS_ENVIRONMENT" => nil, **gemfile }
      end

      def arguments(held, top)
        value = held.to_h { |name, field| [name, plain(field)] }
        report = value[:report].nil? ? value[:refusal] : value[:report]
        fields = { run: "#{value[:run]}-#{value[:status]}", checkout: File.join(top, ""), outcome: value[:status],
                   report: report, **value.slice(*COPIED) }
        ["PushOutcome.record!", *fields.compact.map { |name, field| "#{name}.value=#{field}" }]
      end

      def recorded?(result) = result.ok? && !result.out.include?('"refusal": "')

      def said(result) = (result.err.strip.empty? ? result.out : result.err).strip[0, 300]

      def plain(argument) = argument.is_a?(Hash) ? argument[:value] : argument
    end
  end
end
