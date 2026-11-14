# frozen_string_literal: true

module Hecks
  module Adapters
    class MachineSampling
      # What each gauge's reading leaves the machine as, against its marks and the state it stood
      # in: a reading beyond a mark changes the state, a reading in the gap keeps it. The CPU idle
      # percentage decides the load; the load average only tips it when the CPU does not already
      # say, because it counts processes waiting on swap and disk and so overstates CPU use.
      class States
        # The states the machine starts in.
        START = { load: "below", memory: "ok", lane: "idle" }.freeze

        # @param readings [Hash{Symbol => Float, nil}] `cpu_idle`, `load`, `swap_used_mb`,
        #   `free_gb`, `compressor_gb` and `lane_waiting`; a gauge that could not be read is nil
        # @param marks [Hash{Symbol => Float}] see {Marks}
        # @param before [Hash{Symbol => String}] the states from the last reading
        def initialize(readings, marks, before)
          @readings = readings
          @marks = marks
          @before = START.merge(before.compact)
        end

        # @return [Hash{Symbol => String}] each state after and before, as the answer carries them
        def to_h
          after = { load: load, memory: memory, lane: lane }
          named(after, "state").merge(named(@before, "before"))
        end

        private

        def named(states, suffix) = states.to_h { |gauge, state| [:"#{gauge}_#{suffix}", state] }

        def load
          return "above" if busy?

          calm? ? "below" : @before[:load]
        end

        def busy?
          idle = @readings[:cpu_idle]
          return true if idle && idle <= @marks[:cpu_idle_low]

          heavy? && (idle.nil? || idle < @marks[:cpu_idle_high])
        end

        def calm?
          idle = @readings[:cpu_idle]
          return true if idle && idle >= @marks[:cpu_idle_high]

          light? && (idle.nil? || idle > @marks[:cpu_idle_low])
        end

        def heavy? = @readings[:load].to_f > @marks[:load_high]

        def light? = !@readings[:load].nil? && @readings[:load] < @marks[:load_low]

        # Swap is judged in megabytes and only while free plus inactive memory is short now: macOS
        # resizes its swap file and rarely gives it back, so a large idle swap says nothing alone.
        def memory
          return "low" if pressed? && strained?

          recovered? ? "ok" : @before[:memory]
        end

        def pressed? = @readings[:free_gb].nil? || @readings[:free_gb] < @marks[:free_gb_low]

        def strained?
          @readings[:swap_used_mb].to_f > @marks[:swap_used_mb] || @readings[:compressor_gb].to_f > @marks[:compressor_gb]
        end

        def recovered?
          free = @readings[:free_gb]
          swap = @readings[:swap_used_mb]
          (free && free >= @marks[:free_gb_recovered]) || (swap && swap < @marks[:swap_recovered_mb])
        end

        def lane
          waiting = @readings[:lane_waiting]
          return @before[:lane] if waiting.nil?
          return "busy" if waiting >= @marks[:lane_busy]

          waiting <= @marks[:lane_idle] ? "idle" : @before[:lane]
        end
      end
    end
  end
end
