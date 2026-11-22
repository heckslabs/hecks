# frozen_string_literal: true

require_relative "started_work"

module Hecks
  module Adapters
    # Which keys a work item waits on name no work item, for the `WorkAreas` port's
    # `check_wait_keys`: each unknown key comes with the real keys nearest to it.
    module WaitKeys
      # How many real keys an unknown key is offered beside.
      NEAREST = 3

      module_function

      # @param registry [Runtime::Registry, nil] the booted registry whose Work items are read
      # @param waits_on [Array<Hash, String>] the keys a work item waits on
      # @return [Array<String>] one sentence for each key no work item has
      def unknown(registry, waits_on)
        real = keys(registry)
        names(waits_on).reject { |key| real.include?(key) }.map { |key| sentence(key, real) }
      end

      # @return [Array<String>] the key of every work item the registry holds
      def keys(registry)
        aggregate = StartedWork.work_aggregate(registry)
        return [] unless aggregate

        registry.repository("Tickets", aggregate).all.map { |record| StartedWork.value(record, :work).to_s }
      end

      # @return [Array<String>] the keys, each unwrapped from its value object
      def names(waits_on) = Array(waits_on).map { |key| (key.is_a?(Hash) ? key[:value] : key).to_s }

      # @return [String] the refusal for a key no work item has, naming the nearest real keys
      def sentence(key, real)
        near = real.min_by(NEAREST) { |other| distance(key, other) }
        "#{key} names no work item (one key at a time; nearest: #{near.join(", ")})"
      end

      # @return [Integer] the edit distance between two keys
      def distance(from, to)
        row = (0..to.size).to_a
        from.each_char.with_index(1) { |a, i| row = step(row, a, to, i) }
        row.last
      end

      # @return [Array<Integer>] the next row of the edit-distance table
      def step(previous, char, to, index)
        to.each_char.with_index(1).each_with_object([index]) do |(other, j), row|
          row << [previous[j] + 1, row[j - 1] + 1, previous[j - 1] + (char == other ? 0 : 1)].min
        end
      end
    end
  end
end
