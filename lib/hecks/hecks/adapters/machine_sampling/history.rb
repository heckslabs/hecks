# frozen_string_literal: true

require_relative "../started_work"

module Hecks
  module Adapters
    class MachineSampling
      # The states the machine stands in, read from a booted registry and never written. The load
      # is the one `LoadStanding` record of the machine, which every reading turns, so a reading
      # and the fill that follows it stand on the same load whichever key took the reading. Memory
      # and the test lane are the states the last `Machine` reading left: the one taken latest by
      # its `taken_at` stamp, never the last by key, since a store lists records by key and a key
      # that sorts after the beat's keys would otherwise stand as the last reading for good.
      class History
        # The key of the machine's one load standing.
        STANDING = "machine"

        # @param registry [Runtime::Registry, nil]
        def initialize(registry)
          @registry = registry
        end

        # @return [Hash{Symbol => String}] `load`: where the load standing stands, absent while no
        #   standing is open; `memory` and `lane`: the states the newest recorded reading left,
        #   absent when none is recorded or the records are not readable
        def states
          record = newest
          { load: standing, memory: record && value(record, :memory_state),
            lane: record && value(record, :lane_state) }.compact
        end

        private

        def standing
          record = records("LoadStanding").find { |held| value(held, :standing) == STANDING }
          record && value(record, :load)
        end

        # The stamped reading taken latest, ties going to the later listed; the last listed
        # reading only when none carries a stamp.
        def newest
          held = records("Machine").select { |record| value(record, :load_state) }
          stamped = held.each_with_index.reject { |record, _| value(record, :taken_at).to_s.empty? }
          return held.last if stamped.empty?

          stamped.max_by { |record, index| [value(record, :taken_at), index] }.first
        end

        def records(name)
          aggregate = aggregate_named(name)
          aggregate ? @registry.repository("Hecks", aggregate).all.to_a : []
        end

        def aggregate_named(name)
          bluebook = @registry&.bluebook("Hecks")
          bluebook&.aggregates&.find { |candidate| candidate.hecks_name == name }
        end

        def value(record, name) = StartedWork.value(record, name)&.to_s
      end
    end
  end
end
