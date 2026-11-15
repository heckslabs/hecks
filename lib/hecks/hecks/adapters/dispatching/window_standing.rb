# frozen_string_literal: true

require_relative "../started_work"

module Hecks
  module Adapters
    class Dispatching
      # Whether a merge window is open, read from the `MergeWindow` records of a booted registry and
      # never written. An open window pauses the fill without touching the owner's own switch.
      module WindowStanding
        module_function

        # @param registry [Runtime::Registry, nil]
        # @return [Boolean] whether any window is open; false when none is recorded or they cannot
        #   be read, so a fault in this read never holds the pipeline
        def open?(registry)
          aggregate = window(registry)
          return false unless aggregate

          registry.repository("Hecks", aggregate).all.any? { |record| StartedWork.value(record, :status).to_s == "open" }
        rescue StandardError
          false
        end

        def window(registry)
          bluebook = registry&.bluebook("Hecks")
          bluebook&.aggregates&.find { |candidate| candidate.hecks_name == "MergeWindow" }
        end
      end
    end
  end
end
