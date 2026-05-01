# Hecks::Adapters::PStoreAdapter
#
# File-based object store using Ruby's stdlib PStore. Zero external
# dependencies. Persists aggregates as marshalled Ruby objects in a
# single file per aggregate. Good for integration testing without a
# database server.
#
#   app = Hecks::Runtime.new(domain) do
#     adapter "Pizza", Hecks::Adapters::PStoreAdapter.new("tmp/pizzas.pstore")
#   end
#
require "pstore"

module Hecks
  module Adapters
    class PStoreAdapter
      def initialize(path)
        @store = PStore.new(path)
      end

      def find(id)
        @store.transaction(true) { @store[id] }
      end

      def save(aggregate)
        @store.transaction { @store[aggregate.id] = aggregate }
        aggregate
      end

      def delete(id)
        @store.transaction { @store.delete(id) }
      end

      def all
        @store.transaction(true) { @store.roots.map { |k| @store[k] } }
      end

      def count
        @store.transaction(true) { @store.roots.size }
      end

      def clear
        @store.transaction { @store.roots.each { |k| @store.delete(k) } }
      end

      def query(conditions: {}, order_key: nil, order_direction: :asc, limit: nil, offset: nil)
        results = all
        conditions.each do |k, v|
          results = results.select { |r| r.respond_to?(k) && match?(r.send(k), v) }
        end
        if order_key
          results = results.sort_by { |r| r.respond_to?(order_key) ? r.send(order_key) : nil }
          results = results.reverse if order_direction == :desc
        end
        results = results.drop(offset) if offset
        results = results.first(limit) if limit
        results
      end

      private

      def match?(actual, expected)
        if expected.is_a?(Hecks::Querying::Operators::Operator)
          expected.match?(actual)
        else
          actual == expected
        end
      end
    end
  end
end
