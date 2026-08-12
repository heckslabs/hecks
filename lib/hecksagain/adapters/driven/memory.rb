require_relative "../../ports/persistence/append_only"
require_relative "../../ports/query/in_memory"
require_relative "in_memory_ordering"
require_relative "../../runtime/instance"

module Hecksagain
  module Adapters
    class Memory
      attr_reader :aggregate

      def initialize(aggregate:, settings: {}, root: nil)
        @aggregate = aggregate
        @records   = {}
        @events    = []
        @entries   = []
      end

      def find(id) = @records[id.to_s]
      def count    = @records.size

      def all(order_by: nil, direction: :asc)
        InMemoryOrdering.ordered(@records.values, aggregate: @aggregate, order_by: order_by, direction: direction)
      end

      def query(specification, args = {}, context: {})
        Ports::Query::InMemory.execute(all, specification, args, registry: context[:registry])
      end

      def append(entry)
        @entries << entry
        entry
      end

      def project(entry)
        if entry.save?
          @records[entry.id] = Runtime::Instance.new(aggregate: @aggregate, id: entry.id, state: entry.state.dup)
        else
          @records.delete(entry.id)
        end
      end

      def save(instance)
        entry = Ports::Persistence::Entry.new(operation: "save", id: instance.id.to_s, state: instance.state.dup)
        append(entry)
        project(entry)
      end

      def delete(id)
        entry = Ports::Persistence::Entry.new(operation: "delete", id: id.to_s, state: nil)
        append(entry)
        project(entry)
      end

      def record_event(event) = @events << event

      def events = @events

      def entries = @entries.dup
    end
  end
end
