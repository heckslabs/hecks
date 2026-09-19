require_relative "../../ports/persistence/append_only"
require_relative "../../ports/query/in_memory"
require_relative "in_memory_ordering"
require_relative "../../runtime/instance"

module Hecks
  module Adapters
    # **A browser-hosted domain's own declared intent** — not a second Memory
    # wearing a different name. Ruby has no way to reach a real browser's
    # `window.localStorage` at all (it is per-tab, per-origin, JS-only,
    # unreachable over any network the way D1's own REST API is) — so
    # this Ruby-side adapter is honestly a stand-in: in-process, ephemeral,
    # mechanically identical to Memory. What earns it a name of its own
    # is what it declares, not what it happens to do in Ruby: `persisted_by
    # "LocalStorage"` says "this domain expects real, durable, single-
    # device storage the moment it's actually running where it's meant to
    # run" — the same distinction Heki (real local durability) already
    # draws against Memory (deliberately ephemeral, test/example-only),
    # one adapter over. `bin/console`, the fuzzer, `spec/`, `bin/
    # model_check` all get a domain that boots and behaves correctly
    # against this adapter; only a real browser gets the real durability.
    #
    # The real browser half lives outside this file entirely: `rust/web`'s
    # `dispatch(json)` (docs/implemented/decisions/0015) takes an optional
    # `"seed"` (the exact `"instances"` shape it also answers with) plus
    # `"steps"` — a host rehydrates from a prior snapshot and replays only
    # the new command(s), rather than the whole history every call. A
    # page bound to this adapter is expected to hold that snapshot in
    # `window.localStorage` itself (get on load, set after every
    # `dispatch`) — the seed/instances round trip is the adapter, once
    # you're in the one runtime that can actually reach the storage this
    # name promises.
    class LocalStorage
      # Tenant-capable trivially, same reasoning as Memory's own — a
      # browser tab is exactly one origin, exactly one user; there is no
      # second tenant this in-process Hash could ever confuse a first
      # one with.
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
      # The decision the guide asks for, made explicitly: no compiled
      # dialect of its own, same as Heki/Memory — a personal-scale local
      # store answering by walking `all` is correct on day one, and
      # nothing about a browser tab's own data volume asks for pushdown.
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
      # Through the state codec, the same as Memory (see its `append`).
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

      # Empties the records, journal and event log, keeping the adapter itself.
      #
      # @return [Adapters::LocalStorage] self, now empty
      def reset!
        @records = {}
        @events  = []
        @entries = []
        self
      end

      private

      def copy(state) = Ports::Persistence::StateCodec.copy(@aggregate, state)

      # Not lineage_capable? — deliberately absent, the same trade Heki
      # makes and states plainly (writing-an-adapter.md's own section on
      # it): a domain bound here has no edge for its own shape to travel
      # across if it ever changes; that must be hand-migrated, or the
      # shape must not change. A browser-local personal store is exactly
      # the small-adapter case that guide names as a fine place to make
      # that trade.
    end
  end
end
