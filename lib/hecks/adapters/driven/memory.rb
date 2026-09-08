require_relative "../../ports/persistence/append_only"
require_relative "../../ports/query/in_memory"
require_relative "in_memory_ordering"
require_relative "../../runtime/instance"

module Hecks
  module Adapters
    # The default, no-external-dependency persistence/query adapter — a
    # plain in-process Hash of `Runtime::Instance` records per aggregate,
    # with an append-only `@entries`/`@events` log alongside it. Every
    # behaviors suite must resolve to this one (see
    # Behaviors::Expectations#guard_memory_only!) precisely because a fresh
    # instance really is a fresh store, with nothing shared across tests or
    # tenants.
    class Memory
      # TENANT-CAPABLE TRIVIALLY — see Runtime::TenantCheck's own header
      # for the full reasoning. `@records` is a plain instance variable;
      # two `Runtime.boot` calls build two entirely separate Registry
      # objects and, through them, two entirely separate Memory
      # instances, so two tenant boots never share this adapter's state
      # by construction — nothing here needs to know "tenant" exists.
      def self.tenant_capable? = true
      def persistence_capabilities = [:atomic_put]

      attr_reader :aggregate, :events

      def initialize(aggregate:, settings: {}, root: nil)
        @aggregate = aggregate
        @records   = {}
        @events    = []
        @entries   = []
        @outbox    = []
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

      # One in-memory critical section in the only thread touching this plain
      # Hash: classify and replace without a preliminary repository lookup.
      # Durable append and projection remain ordered exactly as ordinary save.
      def atomic_put(entry, insert_only: false)
        exists = @records.key?(entry.id.to_s)
        return :conflicted if insert_only && exists

        status = exists ? :replaced : :inserted
        append(entry)
        project(entry)
        status
      end

      def delete(id)
        entry = Ports::Persistence::Entry.new(operation: "delete", id: id.to_s, state: nil)
        append(entry)
        project(entry)
      end

      def record_event(event) = @events << event

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
        @outbox  = []
        self
      end

      # No rollback here — a Hash has no transaction to join. Memory
      # implements `transaction` so `Interpreting#run_dispatch_order` has
      # one shape to call, and the outbox so a spec can watch rows move
      # pending → claimed → delivered without a database (the same
      # reason Memory records `events`). See `Runtime::Outbox`.
      def transaction = yield

      def outbox_enqueue(rows)
        rows.filter_map do |row|
          next nil if @outbox.any? { |held| held.delivery_id == row.delivery_id }

          row.id = @outbox.size + 1
          @outbox << row
          row
        end
      end

      def outbox_claim(id) # rubocop:disable Naming/PredicateMethod
        row = @outbox.find { |held| held.id == id }
        return false unless row&.pending?

        row.status = "claimed"
        row.attempts += 1
        true
      end

      def outbox_settle(id, status:, error: nil) # rubocop:disable Naming/PredicateMethod
        row = @outbox.find { |held| held.id == id } or return false
        row.status = status.to_s
        row.error  = error
        true
      end

      def outbox_rows(status: nil)
        rows = status ? @outbox.select { |row| row.status == status.to_s } : @outbox
        rows.map(&:dup)
      end
    end
  end
end
