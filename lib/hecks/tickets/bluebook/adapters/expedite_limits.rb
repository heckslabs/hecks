# frozen_string_literal: true

require "hecks/hecks/adapters/started_work"

module Hecks
  module Adapters
    # The `ExpediteLimits` port's adapter for `Tickets::Work`: reads which other planned or started
    # work items hold the priority lane.
    #
    # It judges nothing: `Work.Unexpedite` compares the count with the lane's limit. It reads the
    # registry's Work items and never writes.
    class ExpediteLimits
      # The priority that holds a place in the lane.
      LANE = "expedite"

      # The statuses whose items hold a place in the lane.
      OPEN = %w[planned started].freeze

      # @param registry [Runtime::Registry, nil] the booted registry whose Work items are read
      # @param aggregate [Object, nil] unused
      def initialize(registry: nil, aggregate: nil)
        @registry = registry
      end

      # The other work items in the lane, as facts.
      #
      # @param held [Hash] the Work item: `work`
      # @return [Hash{Symbol => Hash}] `holders`, their keys in words, and `held`, how many
      def check_expedite(**held)
        others = holders - [plain(held[:work]).to_s]
        { holders: { value: others.join(", ") }, held: { value: others.size } }
      end

      private

      def holders
        aggregate = StartedWork.work_aggregate(@registry)
        return [] unless aggregate

        @registry.repository("Tickets", aggregate).all.filter_map { |record| holder(record) }
      end

      def holder(record)
        return unless StartedWork.value(record, :priority).to_s == LANE
        return unless OPEN.include?(StartedWork.value(record, :status).to_s)

        StartedWork.value(record, :work).to_s
      end

      def plain(argument) = argument.is_a?(Hash) ? argument[:value] : argument
    end
  end
end
