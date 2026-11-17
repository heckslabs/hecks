# frozen_string_literal: true

module Hecks
  module Adapters
    class MainIntegration
      # The first merge, among the landings a failed verification covers, whose own specs fail:
      # a binary search over the merges oldest first, one probe per step. It reads facts and
      # writes none: nothing is reverted, marked or raised here, and a probe that errors, a head
      # that moved or a spent budget answers nil, never an exception.
      #
      # The search assumes a failure stays once it appears. When a later merge mends it, the
      # answer is still the first merge that failed, which the mend may already have fixed.
      class FirstBad
        # The most probes one search makes; each is a clean copy and an impacted-spec run.
        LIMIT = 6

        # @param merges [Array<Hash>] the landings, oldest first (`Repository#merges`)
        # @param probe [#call] given a merge, answers `[ok, finding]`; `finding` is a Hash with
        #   `:spec` and `:example` when it failed
        # @param current [#call] answers whether the commit being verified is still the head
        # @param limit [Integer] the most probes to make
        def initialize(merges, probe:, current: -> { true }, limit: LIMIT)
          @merges = merges
          @probe = probe
          @current = current
          @limit = limit
        end

        # @return [Hash, nil] the merge (`sha:`, `subject:`, `paths:`) with its `finding:`, or nil
        #   when none failed or the search could not finish
        def call
          @low = 0
          @high = @merges.size - 1
          @found = nil
          @spent = 0
          step while @low <= @high
          @found
        rescue StandardError, ConsoleCapture::Failure
          nil
        end

        private

        def step
          raise ConsoleCapture::Failure, "search stopped" if @spent >= @limit || !@current.call

          middle = (@low + @high) / 2
          ok, finding = @probe.call(@merges[middle])
          @spent += 1
          ok ? @low = middle + 1 : fail_at(middle, finding)
        end

        def fail_at(middle, finding)
          @found = @merges[middle].merge(finding: finding || {})
          @high = middle - 1
        end
      end
    end
  end
end
