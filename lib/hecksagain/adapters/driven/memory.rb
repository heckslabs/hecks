require_relative "../../ports/persistence/append_only"
require_relative "../../ports/query/in_memory"
require_relative "in_memory_ordering"
require_relative "../../runtime/instance"

module Hecksagain
  module Adapters
    class Memory
      # TENANT-CAPABLE TRIVIALLY — see Runtime::TenantCheck's own header
      # for the full reasoning. `@records` is a plain instance variable;
      # two `Runtime.boot` calls build two entirely separate Registry
      # objects and, through them, two entirely separate Memory
      # instances, so two tenant boots never share this adapter's state
      # by construction — nothing here needs to know "tenant" exists.
      def self.tenant_capable? = true

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

      # Every other driven adapter (Postgres/PostgresEra/Sqlite/D1)
      # already implements this — `Ports::Persistence::AppendOnly#reset!`
      # forwards to it and only raises when the wrapped adapter doesn't
      # respond to `reset!` at all, which was always this adapter's own
      # gap, not a deliberate omission (nothing about "in memory" implies
      # "cannot be cleared"). Existing callers that fully re-`Hecks.boot`
      # a domain per test case don't need this — they get a brand new
      # `Memory` instance, with brand new empty `@records`/`@events`/
      # `@entries`, for free. This is for the other case: a caller that
      # deliberately keeps ONE booted runtime across many cases (to skip
      # `load_domain`'s own per-boot parse/verify cost) and wants each
      # case to start from the same clean slate `Hecks.boot` would have
      # given it, without paying for a fresh boot to get there.
      def reset!
        @records = {}
        @events  = []
        @entries = []
        self
      end
    end
  end
end
