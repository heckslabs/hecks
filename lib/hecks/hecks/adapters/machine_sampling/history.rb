# frozen_string_literal: true

require_relative "../started_work"

module Hecks
  module Adapters
    class MachineSampling
      # The states the last reading of the machine left, read from the `Machine` records of a
      # booted registry and never written.
      class History
        # @param registry [Runtime::Registry, nil]
        def initialize(registry)
          @registry = registry
        end

        # @return [Hash{Symbol => String}] `load`, `memory` and `lane`: each the state the newest
        #   recorded reading left; empty when none is recorded, or the records are not readable
        def states
          record = records.reverse.find { |held| value(held, :load_state) }
          return {} unless record

          { load: value(record, :load_state), memory: value(record, :memory_state), lane: value(record, :lane_state) }
        end

        private

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
