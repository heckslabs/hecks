# frozen_string_literal: true

module Hecks
  module Adapters
    # The `Signalling` port's adapter for the Hecks domain's `Heartbeat` (ADR 0222, phase 3b): on
    # a clock beat it begins Signalbox's pressure beat, keyed by the clock's beat, in the registry
    # that attaches Signalbox. The Hecks domain conforms to Signalbox, so the beat is asked for
    # here and Signalbox hears no Hecks event. It decides nothing: Signalbox's own chain looks,
    # clears and posts.
    class Signalling
      # Refused when the asking registry has no Signalbox to beat.
      class Unsignalled < StandardError; end

      # The command that begins a pressure beat.
      VERB = "Signalbox::Beat.Begin"

      # @param registry [Runtime::Registry, nil] the registry that attaches Signalbox
      # @param aggregate [Object, nil] unused
      # @param settings [Hash] `dispatch:` a stand-in that begins the beat from its key
      # @param root [String, nil] unused
      def initialize(registry: nil, aggregate: nil, settings: {}, root: nil)
        @registry = registry
        @dispatch = settings[:dispatch] || method(:begin_beat)
      end

      # @param held [Hash] the `Heartbeat` record: `beat`
      # @return [Hash{Symbol => Hash}] `beat:` the key the pressure beat was begun under
      # @raise [Unsignalled] when Signalbox is not attached where the clock beats
      def signal(**held)
        beat = held[:beat].is_a?(Hash) ? held[:beat][:value] : held[:beat]
        raise Unsignalled, "Signalbox is not attached here" unless attached?

        @dispatch.call(beat.to_s)
        { beat: { value: beat.to_s } }
      end

      private

      def attached? = @registry.nil? || !@registry.bluebooks.to_h["Signalbox"].nil?

      def begin_beat(beat)
        Runtime::Dispatcher.new(@registry).dispatch(VERB, with: { beat: { value: beat } })
      end
    end
  end
end
