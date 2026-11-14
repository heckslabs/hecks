# frozen_string_literal: true

require_relative "started_work"

module Hecks
  module Adapters
    # The branches a booted registry holds a landed `Landing` row for. The `Leftovers` port reads
    # them to know which worktrees came from a landing, so a branch that was only opened is never
    # listed. It writes nothing.
    module LandedBranches
      module_function

      # @param registry [Runtime::Registry, nil] the booted registry; nil reads no rows
      # @return [Array<String>] each landed branch once, in the order its rows come
      def of(registry)
        aggregate = landing_aggregate(registry)
        return [] unless aggregate

        rows = registry.repository("Delivery", aggregate).all
        rows.filter_map { |record| branch(record) }.uniq
      end

      # @return [Object, nil] the Landing aggregate, nil when no Hecks bluebook is booted
      def landing_aggregate(registry)
        bluebook = registry&.bluebook("Delivery")
        bluebook&.aggregates&.find { |candidate| candidate.hecks_name == "Landing" }
      end

      # @return [String, nil] the row's branch, nil unless the row landed and names one
      def branch(record)
        return unless StartedWork.value(record, :status) == "landed"

        name = StartedWork.value(record, :branch).to_s
        name unless name.empty?
      end
    end
  end
end
