# frozen_string_literal: true

require_relative "../../adapters/qa_quiesce_marker"

module Hecks
  module QualityControlCli
    class QaTick
      # Keeps a tick quiet while QA is quiesced for a mint window. Before each step the tick asks
      # whether the `quiesced` dial is on or a fresh marker (`hecks qa_quiesce.hold!`) exists;
      # if so the step does not start: `quiesced: skipped <step>` is printed and the step counts
      # as clean, so the tick exits 0. The marker is read again before every step, so a hold set
      # while a tick runs stops the steps after it. A stale marker is ignored, and said once per
      # tick.
      module QuiesceGuard
        private

        # Runs a step unless QA is quiesced.
        #
        # @param name [String] the step's name, as the report prints it
        # @yieldreturn [Array(String, Integer)] the step's output and exit status
        # @return [Step] the step's result, or a clean skipped step
        def guarded(name)
          skipped = quiesced_reason
          return Step.new(name, *yield) unless skipped

          message = "quiesced: skipped #{name} (#{skipped})"
          puts message
          Step.new(name, message, 0)
        end

        # @return [String, nil] why QA is quiet right now, or nil when steps may run
        def quiesced_reason
          return "the quiesced dial is on" if dial(:QUIESCED, false)

          marker = @quiesce_marker ||= Adapters::QaQuiesceMarker.new
          report_stale(marker)
          hold = marker.active
          marker.describe(hold) if hold
        end

        def report_stale(marker)
          stale = marker.stale
          return if stale.nil? || @stale_reported

          @stale_reported = true
          puts "quiesce marker is stale and ignored: #{marker.describe(stale)}"
        end
      end
    end
  end
end
