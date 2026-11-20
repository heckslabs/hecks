# frozen_string_literal: true

require_relative "console_capture"
require_relative "dial_turning/turnables"
require_relative "probe_measuring/tally"
require "hecks/runtime/event_tap"
require_relative "../../pipeline_board/adapters/pipeline_journal/tap"

module Hecks
  module Adapters
    # The `Measuring` port's adapter for `Probe`: counts the pipeline from the runtime's event log
    # over the span before a turn (`Measure`) and over the window after it (`Judge`), and says what
    # the probed setting stands at now. It only counts; the `Probe` givens judge. It opens the log
    # for reading only and writes nothing.
    class ProbeMeasuring
      # @param aggregate [Bluebook::Aggregate, nil] unused
      # @param registry [Runtime::Registry, nil] the booted registry whose worlds and `Turnable`
      #   rows are read
      # @param settings [Hash] `rows:` stands in for the event log (a callable answering its rows of
      #   {Tally::NAMES}), `tap:` for its path, and `standing:` for what reads a setting's value now
      # @param root [String, nil] unused
      def initialize(aggregate: nil, registry: nil, settings: {}, root: nil)
        @registry = registry
        @rows = settings[:rows] || method(:logged)
        @tap = settings.fetch(:tap) { logged_at(registry) }
        @standing = settings[:standing] || method(:standing_of)
      end

      # @param held [Hash] the `Probe` record: `opened_at` and `span`
      # @return [Hash{Symbol => Hash}] the counts over the span before the turn
      def measure(**held)
        opened = number(held[:opened_at])
        Tally.of(@rows.call, opened - number(held[:span]), opened)
      end

      # @param held [Hash] the `Probe` record: `opened_at`, `window` and `setting`
      # @return [Hash{Symbol => Hash}] the counts over the window after the turn, and `standing:`
      #   what the setting stands at now, in words
      def judge(**held)
        opened = number(held[:opened_at])
        Tally.of(@rows.call, opened, opened + number(held[:window]))
             .merge(standing: { value: @standing.call(plain(held[:setting]).to_s).to_s })
      end

      private

      # The rows of the whole log, its rotated generations too; none when no log is kept.
      def logged
        @tap ? PipelineBoard::Tap.new(File.expand_path(@tap), names: -> { Tally::NAMES }).named(Tally::NAMES) : []
      end

      # Where the Hecks world's event log is written, nil when it keeps none.
      def logged_at(registry)
        Runtime::EventTap.path_for(registry&.world("Hecks")&.for_verb(Runtime::EventTap::VERB).to_h)
      end

      # The setting's value as the booted worlds hold it, every local file read.
      def standing_of(setting)
        row = DialTurning::Turnables.from_registry(@registry).find { |candidate| candidate[:setting] == setting }
        return "" unless row

        verb, key = setting.split(".")
        (@registry&.world(row[:world])&.for_verb(verb) || {})[key.to_sym]
      end

      def number(argument) = Integer(plain(argument) || refuse!("the probe holds no #{argument.inspect} time"))

      def plain(argument) = argument.is_a?(Hash) ? argument[:value] : argument

      def refuse!(message) = raise(ConsoleCapture::Failure, message)
    end
  end
end
