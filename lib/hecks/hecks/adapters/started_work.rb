# frozen_string_literal: true

module Hecks
  module Adapters
    # The started `Tickets::Work` items of a booted registry, with the area each one claims. The
    # `WorkAreas` and `Landing` adapters both read claims through this.
    module StartedWork
      module_function

      # @param registry [Runtime::Registry, nil] the booted registry; nil reads no work items
      # @return [Array<Hash{Symbol => Object}>] `key:`, `title:`, `area:` of each started work
      #   item
      def items(registry)
        aggregate = work_aggregate(registry)
        return [] unless aggregate

        registry.repository("Tickets", aggregate).all.filter_map { |record| item(record) }
      end

      # @return [Object, nil] the Work aggregate, nil when no Tickets bluebook is booted
      def work_aggregate(registry)
        bluebook = registry&.bluebook("Tickets")
        bluebook&.aggregates&.find { |candidate| candidate.hecks_name == "Work" }
      end

      # @return [Hash, nil] the work item's key and area, nil unless the work item is started
      def item(record)
        return unless value(record, :status) == "started"

        { key: value(record, :work).to_s, title: value(record, :title).to_s, area: words(value(record, :area)) }
      end

      # @return [Array<String>] the areas of a list of Word values
      def words(list) = Array(list).map { |word| (value(word, :value) || word).to_s }

      # @return [Object, nil] a field of a record or hash, unwrapped from its value object; nil when
      #   the record has no such field
      def value(record, name)
        found = record.respond_to?(name) ? record.public_send(name) : indexed(record, name)
        found.respond_to?(:value) ? found.value : found
      end

      # @return [Object, nil] the entry of a hash or the member of a struct, nil when it has none
      def indexed(record, name)
        return unless record.respond_to?(:[])
        return if record.is_a?(Struct) && !record.members.include?(name.to_sym)

        record[name]
      end
    end
  end
end
