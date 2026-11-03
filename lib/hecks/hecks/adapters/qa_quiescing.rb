# frozen_string_literal: true

require_relative "console_capture"
require "hecks/quality_control/adapters/qa_quiesce_marker"

module Hecks
  module Adapters
    # The `Quiescing` port's adapter: writes, removes and reads the QA quiet marker
    # (`QaQuiesceMarker`). It touches no ledger and no git state.
    class QaQuiescing
      # @param aggregate [Object, nil] unused
      # @param settings [Hash] `marker:` a `QaQuiesceMarker`, for a spec
      # @param root [String, nil] unused
      def initialize(aggregate: nil, settings: {}, root: nil)
        @marker = settings[:marker] || QaQuiesceMarker.new
      end

      # Writes the marker.
      #
      # @param held [Hash] the `QaQuiesce` record: `reason`, optional `owner` and `force`
      # @return [Hash{Symbol => Hash}] `output:` what was held
      # @raise [ConsoleCapture::Failure] when another owner holds a fresh marker
      def mark(**held)
        hold = @marker.hold!(owner: owner(held), reason: plain(held[:reason]), force: plain(held[:force]) == true)
        { output: { value: "quiesced: #{@marker.describe(hold)}" } }
      rescue QaQuiesceMarker::Refused => e
        raise ConsoleCapture::Failure, e.message
      end

      # Removes the marker.
      #
      # @param held [Hash] the `QaQuiesce` record: optional `owner` and `force`
      # @return [Hash{Symbol => Hash}] `output:` what was released
      # @raise [ConsoleCapture::Failure] when another owner holds a fresh marker
      def clear(**held)
        removed = @marker.release!(owner: owner(held), force: plain(held[:force]) == true)
        { output: { value: removed ? "released: #{@marker.describe(removed)}" : "released: no marker was held" } }
      rescue QaQuiesceMarker::Refused => e
        raise ConsoleCapture::Failure, e.message
      end

      # @return [Hash{Symbol => String}] `text:` owner, reason and age of the marker
      def status(**)
        { text: @marker.status }
      end

      private

      # The caller's name for the hold: the argument, else `HECKS_QUIESCE_OWNER`, else "unnamed".
      def owner(held)
        plain(held[:owner]) || ENV["HECKS_QUIESCE_OWNER"] || "unnamed"
      end

      def plain(argument) = argument.is_a?(Hash) ? argument[:value] : argument
    end
  end
end
