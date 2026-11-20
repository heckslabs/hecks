# frozen_string_literal: true

require "fileutils"
require "json"
require "time"
require "hecks/signalbox/adapters/looking/marks"
require "hecks/signalbox/adapters/pressure_signal"

module Hecks
  module Adapters
    # The `PressurePosting` port's adapter for Signalbox's `Pressure` (ADR 0222 law 2, phase 3b):
    # it posts the settled Pressure as the machine's one signal, a JSON file {PressureSignal} reads
    # from any process. It stamps the time it posted and the age past which the signal is dark,
    # and judges nothing: the band and the room are the bluebook's.
    class PressurePosting
      # The Pressure fields the signal carries.
      FIELDS = %i[pressure band headroom load cores coders_fit gates_fit].freeze

      # @param registry [Runtime::Registry, nil] whose Signalbox world names how long a signal
      #   stays current
      # @param aggregate [Object, nil] unused
      # @param settings [Hash] `path:` the file posted to, `now:` answers the time; the
      #   {PressureSignal.path} and the clock when absent
      # @param root [String, nil] unused
      def initialize(registry: nil, aggregate: nil, settings: {}, root: nil)
        @registry = registry
        @path = settings[:path] || PressureSignal.path
        @now = settings[:now] || -> { Time.now }
      end

      # Posts the Pressure record the ask holds, written whole so a reader never sees half of it.
      #
      # @param held [Hash] the settled `Pressure` record
      # @return [Hash{Symbol => Hash}] `pressure:` the key posted
      # @raise [Looking::Marks::Unread] when the world's marks cannot be read
      def post(**held)
        signal = FIELDS.to_h { |field| [field, plain(held[field])] }
        write(signal.merge(posted_at: @now.call.utc.iso8601, stale_after: stale_after))
        { pressure: { value: signal[:pressure] } }
      end

      private

      # How long a signal stays current, read when it is posted: a world whose line cannot be read
      # raises {Looking::Marks::Unread}, so nothing is posted on a mark the world did not set.
      def stale_after = Looking::Marks.new(@registry).facts[:stale_after]

      def plain(field) = field.is_a?(Hash) ? field[:value] : field

      def write(signal)
        FileUtils.mkdir_p(File.dirname(@path))
        partial = "#{@path}.#{Process.pid}"
        File.write(partial, JSON.generate(signal))
        File.rename(partial, @path)
      end
    end
  end
end
