# frozen_string_literal: true

module Hecks
  module Adapters
    # The started `Tickets::Work` rows of a booted registry, with the area each one claims. The
    # `WorkAreas` and `Landing` adapters both read claims through this.
    module StartedWork
      module_function

      # @param registry [Runtime::Registry, nil] the booted registry; nil reads no rows
      # @return [Array<Hash{Symbol => Object}>] `key:` and `area:` (strings) of each started row
      def rows(registry)
        aggregate = work_aggregate(registry)
        return [] unless aggregate

        registry.repository("Tickets", aggregate).all.filter_map { |record| row(record) }
      end

      # @return [Object, nil] the Work aggregate, nil when no Tickets bluebook is booted
      def work_aggregate(registry)
        bluebook = registry&.bluebook("Tickets")
        bluebook&.aggregates&.find { |candidate| candidate.hecks_name == "Work" }
      end

      # @return [Hash, nil] the row's key and area, nil unless the row is started
      def row(record)
        return unless value(record, :status) == "started"

        { key: value(record, :work).to_s, area: words(value(record, :area)) }
      end

      # @return [Array<String>] the areas of a list of Word values
      def words(list) = Array(list).map { |word| (value(word, :value) || word).to_s }

      # @return [Object] a field of a record or hash, unwrapped from its value object
      def value(record, name)
        found = record.respond_to?(name) ? record.public_send(name) : (record[name] if record.respond_to?(:[]))
        found.respond_to?(:value) ? found.value : found
      end
    end
  end
end
