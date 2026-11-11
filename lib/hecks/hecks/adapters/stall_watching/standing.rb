# frozen_string_literal: true

module Hecks
  module Adapters
    class StallWatching
      # What the event tap already says about the stalls: which were filed, which were abandoned and
      # whether a kind's run has ended. Each beat of the clock is a process of its own with an empty
      # `Stall` store, so the tap is the only memory a later look has.
      class Standing
        # @param lines [Array<Hash>] tap lines in sequence order
        def initialize(lines)
          @lines = lines.select { |line| line["kind"] == "event" }
          @filed = ids("StallFiled")
          @abandoned = ids("StallAbandoned")
        end

        # @param stall [String] a stall key, `stall-<kind>-<subject>`
        # @return [Boolean] whether the tap holds a `StallFiled` for it
        def filed?(stall) = @filed.include?(stall)

        # @param stall [String] a stall key
        # @return [Boolean] whether the tap holds a `StallAbandoned` for it
        def abandoned?(stall) = @abandoned.include?(stall)

        # @param kind [Hash] a `StallKind` row
        # @param subject [String] the opening line's aggregate id, which is also the run's id
        # @return [String, nil] the first event that ended the subject's run; none when the kind
        #   names no ending or the run goes on
        def ending(kind, subject)
          events = kind[:ends].to_s.split(",").map(&:strip)
          found = @lines.find do |line|
            line["aggregate"] == kind[:ends_aggregate] && line["id"].to_s == subject && events.include?(line["event"])
          end
          found && found["event"]
        end

        private

        def ids(event) = @lines.select { |line| line["event"] == event }.to_set { |line| line["id"].to_s }
      end
    end
  end
end
