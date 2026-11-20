# frozen_string_literal: true

require_relative "../started_work"

module Hecks
  module Adapters
    class MachineSampling
      # The states the last reading of the machine left, read from the `Machine` records of a
      # booted registry and never written. The last reading is the one taken latest by its
      # `taken_at` stamp, never the last by key: a store lists records by key, and a key that sorts
      # after the beat's keys would otherwise stand as the last reading for good.
      class History
        # @param registry [Runtime::Registry, nil]
        def initialize(registry)
          @registry = registry
        end

        # @return [Hash{Symbol => String}] `load`, `memory` and `lane`: each the state the newest
        #   recorded reading left; empty when none is recorded, or the records are not readable
        def states
          record = newest
          return {} unless record

          { load: value(record, :load_state), memory: value(record, :memory_state), lane: value(record, :lane_state) }
        end

        private

        # The stamped reading taken latest, ties going to the later listed; the last listed
        # reading only when none carries a stamp.
        def newest
          held = records.select { |record| value(record, :load_state) }
          stamped = held.each_with_index.reject { |record, _| value(record, :taken_at).to_s.empty? }
          return held.last if stamped.empty?

          stamped.max_by { |record, index| [value(record, :taken_at), index] }.first
        end

        def records
          aggregate = machine
          aggregate ? @registry.repository("Hecks", aggregate).all.to_a : []
        end

        def machine
          bluebook = @registry&.bluebook("Hecks")
          bluebook&.aggregates&.find { |candidate| candidate.hecks_name == "Machine" }
        end

        def value(record, name) = StartedWork.value(record, name)&.to_s
      end
    end
  end
end
