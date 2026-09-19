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
      # Reports that two tenant boots of this adapter never share state.
      #
      # **Tenant-capable trivially** — see `Runtime::TenantCheck`'s own header
      # for the full reasoning. `@records` is a plain instance variable;
      # two `Runtime.boot` calls build two entirely separate Registry
      # objects and, through them, two entirely separate Memory
      # instances, so two tenant boots never share this adapter's state
      # by construction — nothing here needs to know "tenant" exists.
      #
      # @return [Boolean] always true
      def self.tenant_capable? = true

      # Names the optional persistence capabilities `Ports::Persistence::AppendOnly` may rely on.
      #
      # @return [Array<Symbol>] `[:atomic_put]`
      def persistence_capabilities = [:atomic_put]

      attr_reader :aggregate, :events

      # @param aggregate [Bluebook::Aggregate] the aggregate whose records this store holds
      # @param settings [Hash] world settings for the binding; accepted for the shared adapter
      #   constructor shape and ignored
      # @param root [String, nil] project root directory; accepted for the shared adapter
      #   constructor shape and ignored
      def initialize(aggregate:, settings: {}, root: nil)
        @aggregate = aggregate
        @records   = {}
        @events    = []
        @entries   = []
        @outbox    = []
      end

      # Looks up the current record for one aggregate identity.
      #
      # @param id [String, Object] the aggregate identity, compared as `id.to_s`
      # @return [Runtime::Instance, nil] the held record, or nil when no record has that id
      def find(id) = @records[id.to_s]

      # Counts the records currently held, deleted ones excluded.
      #
      # @return [Integer] number of live records
      def count    = @records.size

      # Lists every held record, in insertion order unless an ordering attribute is given.
      #
      # @param order_by [String, Symbol, nil] attribute (or dotted value-object path) to sort
      #   by; nil leaves the records in insertion order
      # @param direction [Symbol, String] `:asc` or `:desc`
      # @return [Array<Runtime::Instance>] the held records, `[]` when the store is empty
      # @raise [Runtime::WiringError] if `order_by` names no attribute of the aggregate
      def all(order_by: nil, direction: :asc)
        InMemoryOrdering.ordered(@records.values, aggregate: @aggregate, order_by: order_by, direction: direction)
      end

      # Answers a declared query by filtering, ordering and paging the held records in Ruby.
      #
      # @param specification [QuerySpecification::Common::Options] the declared query
      # @param args [Hash{Symbol => Object}] values for the specification's symbolic operands
      # @param context [Hash] execution context; only `:registry` (a `Runtime::Registry` or
      #   nil) is read, for comparators that look up another aggregate
      # @return [Array<Runtime::Instance>] the matching records, `[]` when none match
      # @raise [Runtime::WiringError] if a where clause uses an operation no comparator handles
      def query(specification, args = {}, context: {})
        Ports::Query::InMemory.execute(all, specification, args, registry: context[:registry])
      end

      # Records one journal entry, holding a codec copy of its state.
      #
      # Through the state codec, like every durable adapter (PR A3): the
      # journal holds `StateCodec.copy` — exactly what an encode-to-JSON
      # then decode would hand back — never the caller's own live state
      # objects, so an entry read back here has the same deep-symbol,
      # plain-Hash shape a Heki/Sqlite/Postgres entry has.
      #
      # @param entry [Ports::Persistence::Entry] the save or delete to journal
      # @return [Ports::Persistence::Entry] the caller's own `entry`, not the journalled copy
      def append(entry)
        copied = Ports::Persistence::Entry.new(operation: entry.operation, id: entry.id,
                                               state: copy(entry.state), mirrors: entry.mirrors)
        @entries << copied
        entry
      end

      # Applies one journal entry to the current-state Hash.
      #
      # @param entry [Ports::Persistence::Entry] the save or delete to materialize
      # @return [Runtime::Instance, nil] the new record for a save; for a delete, the record
      #   removed, or nil when none was held
      def project(entry)
        if entry.save?
          @records[entry.id] = Runtime::Instance.new(aggregate: @aggregate, id: entry.id, state: copy(entry.state))
        else
          @records.delete(entry.id)
        end
      end

      # Journals and materializes an instance's current state in one call.
      #
      # @param instance [Runtime::Instance] the instance to store
      # @return [Runtime::Instance] the stored record, a fresh instance over a copy of the state
      def save(instance)
        entry = Ports::Persistence::Entry.new(operation: "save", id: instance.id.to_s, state: copy(instance.state))
        append(entry)
        project(entry)
      end

      # Stores an entry and reports whether it inserted, replaced or conflicted.
      #
      # One in-memory critical section in the only thread touching this plain
      # Hash: classify and replace without a preliminary repository lookup.
      # Durable append and projection remain ordered exactly as ordinary save.
      #
      # @param entry [Ports::Persistence::Entry] the save to store
      # @param insert_only [Boolean] when true, an existing record is left untouched
      # @return [Symbol] `:inserted`, `:replaced`, or `:conflicted` when `insert_only` met an
      #   existing record and nothing was written
      def atomic_put(entry, insert_only: false)
        exists = @records.key?(entry.id.to_s)
        return :conflicted if insert_only && exists

        status = exists ? :replaced : :inserted
        append(entry)
        project(entry)
        status
      end

      # Journals a delete and removes the record, whether or not one is held.
      #
      # @param id [String, Object] the aggregate identity, journalled as `id.to_s`
      # @return [Runtime::Instance, nil] the record removed, or nil when none was held
      def delete(id)
        entry = Ports::Persistence::Entry.new(operation: "delete", id: id.to_s, state: nil)
        append(entry)
        project(entry)
      end

      # Appends an emitted event to the in-process event log.
      #
      # @param event [Runtime::Event] the emitted event
      # @return [Array<Runtime::Event>] the live event log, including `event`
      def record_event(event) = @events << event

      # Lists the journal in append order, for `AppendOnly#recover!` to replay.
      #
      # @return [Array<Ports::Persistence::Entry>] a copy of the journal, `[]` when nothing
      #   has been appended
      def entries = @entries.dup

      # Empties the records, journal, event log and outbox, keeping the adapter itself.
      #
      # Every other driven adapter (Postgres/PostgresEra/Sqlite/D1)
      # implements this too — `Ports::Persistence::AppendOnly#reset!`
      # forwards to it and only raises when the wrapped adapter doesn't
      # respond to `reset!` at all, and nothing about "in memory" implies
      # "cannot be cleared". Existing callers that fully re-`Hecks.boot`
      # a domain per test case don't need this — they get a brand new
      # `Memory` instance, with brand new empty `@records`/`@events`/
      # `@entries`, for free. This is for the other case: a caller that
      # deliberately keeps one booted runtime across many cases (to skip
      # `load_domain`'s own per-boot parse/verify cost) and wants each
      # case to start from the same clean slate `Hecks.boot` would have
      # given it, without paying for a fresh boot to get there.
      #
      # @return [Adapters::Memory] self, now empty
      def reset!
        @records = {}
        @events  = []
        @entries = []
        @outbox  = []
        self
      end

      # Runs the block directly, as the save + emit + outbox boundary other adapters commit.
      #
      # No rollback here — a Hash has no transaction to join. Memory
      # implements `transaction` so `Interpreting#run_dispatch_order` has
      # one shape to call, and the outbox so a spec can watch rows move
      # pending → claimed → delivered without a database (the same
      # reason Memory records `events`). See `Runtime::Outbox`.
      #
      # @yield the writes to run together; an exception raised inside undoes nothing
      # @return [Object] the block's own result
      def transaction = yield

      # Holds new outbox rows, skipping any whose `delivery_id` is already held.
      #
      # @param rows [Array<Runtime::Outbox::Row>] pending rows to enqueue; each accepted row
      #   has its `id` assigned in place
      # @return [Array<Runtime::Outbox::Row>] the rows actually enqueued, `[]` when every one
      #   was a duplicate
      def outbox_enqueue(rows)
        rows.filter_map do |row|
          next nil if @outbox.any? { |held| held.delivery_id == row.delivery_id }

          row.id = @outbox.size + 1
          @outbox << row
          row
        end
      end

      # Marks a pending outbox row claimed and counts the delivery attempt.
      #
      # @param id [Integer] the row id `outbox_enqueue` assigned
      # @return [Boolean] true when the row was pending and is now claimed; false when it is
      #   unknown or no longer pending
      def outbox_claim(id) # rubocop:disable Naming/PredicateMethod
        row = @outbox.find { |held| held.id == id }
        return false unless row&.pending?

        row.status = "claimed"
        row.attempts += 1
        true
      end

      # Records a delivery outcome on an outbox row, whatever status it held.
      #
      # @param id [Integer] the row id `outbox_enqueue` assigned
      # @param status [String, Symbol] the new status, one of `Runtime::Outbox::STATUSES`;
      #   not validated here
      # @param error [String, nil] the failure description, or nil to clear it
      # @return [Boolean] true when the row exists and was updated; false when no row has `id`
      def outbox_settle(id, status:, error: nil) # rubocop:disable Naming/PredicateMethod
        row = @outbox.find { |held| held.id == id } or return false
        row.status = status.to_s
        row.error  = error
        true
      end

      # Lists outbox rows in enqueue order, as copies a caller may mutate freely.
      #
      # @param status [String, Symbol, nil] only rows with this status; nil lists every row
      # @return [Array<Runtime::Outbox::Row>] shallow copies of the matching rows, `[]` when
      #   none match
      def outbox_rows(status: nil)
        rows = status ? @outbox.select { |row| row.status == status.to_s } : @outbox
        rows.map(&:dup)
      end

      private

      def copy(state) = Ports::Persistence::StateCodec.copy(@aggregate, state)
    end
  end
end
