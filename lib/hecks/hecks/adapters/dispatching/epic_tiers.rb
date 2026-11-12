# frozen_string_literal: true

require_relative "../started_work"

module Hecks
  module Adapters
    class Dispatching
      # The tier of each epic, 1 to 9 (lowest is sooner), read from the booted registry the fill
      # already runs in. It reads and never writes.
      module EpicTiers
        # The tier a work item with no epic, or whose epic has no tier, ranks by: after tier 9.
        UNRANKED = 10

        module_function

        # @param registry [Runtime::Registry, nil] the booted registry; nil reads no epics
        # @return [Hash{String => Integer}] each ranked epic's key with its tier
        def of(registry)
          aggregate = aggregate_of(registry)
          return {} unless aggregate

          epics = registry.repository("Tickets", aggregate).all
          epics.to_h { |epic| [value(epic, :epic).to_s, value(epic, :tier)] }.compact.transform_values(&:to_i)
        end

        # @return [Object, nil] the Epic aggregate, nil when no Tickets bluebook is booted
        def aggregate_of(registry)
          bluebook = registry&.bluebook("Tickets")
          bluebook&.aggregates&.find { |candidate| candidate.hecks_name == "Epic" }
        end

        # @return [Object] a field of an epic record, unwrapped from its value object
        def value(epic, name) = StartedWork.value(epic, name)
      end
    end
  end
end
