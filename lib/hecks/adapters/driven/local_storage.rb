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
      #
      # @return [Boolean] true, always
      def self.tenant_capable? = true

      # Lists the optional persistence behaviours this adapter advertises.
      #
      # @return [Array<Symbol>] `[:atomic_put]`
      def persistence_capabilities = [:atomic_put]

      attr_reader :aggregate, :events

      # @param aggregate [Bluebook::Aggregate] the aggregate this store persists
      # @param settings [Hash] accepted but not read by this class
      # @param root [String, nil] accepted but not read by this class
      def initialize(aggregate:, settings: {}, root: nil)
        @aggregate = aggregate
        @records   = {}
        @events    = []
        @entries   = []
      end

      # Reads one record's current projected state.
      #
      # @param id [String, Object] the record's identity, compared as `id.to_s`
      # @return [Runtime::Instance, nil] the stored record, or nil when no record has that id
      def find(id) = @records[id.to_s]

      # Counts the records currently projected.
      #
      # @return [Integer] number of stored records
      def count    = @records.size

      # Lists every record currently projected.
      #
      # @param order_by [String, Symbol, nil] an attribute name to sort by; nil keeps
      #   insertion order
      # @param direction [Symbol] `:asc` or `:desc`
      # @return [Array<Runtime::Instance>] the stored records; `[]` when there are none
      def all(order_by: nil, direction: :asc)
        InMemoryOrdering.ordered(@records.values, aggregate: @aggregate, order_by: order_by, direction: direction)
      end

      # Answers a declared query specification against the projected records.
      #
      # The decision the guide asks for, made explicitly: no compiled
      # dialect of its own, same as Heki/Memory — a personal-scale local
      # store answering by walking `all` is correct on day one, and
      # nothing about a browser tab's own data volume asks for pushdown.
      #
      # @param specification [QuerySpecification::Common::Options,
      #   Bluebook::Behaviour::ReadModel::FilteredOptions] the declared query specification
      # @param args [Hash{Symbol => Object}] bound values for the specification's placeholders
      # @param context [Hash{Symbol => Object}] call context; `:registry` is read and passed
      #   through for registry-aware comparisons
      # @return [Array<Runtime::Instance>] the matching records, ordered and paged
      def query(specification, args = {}, context: {})
        Ports::Query::InMemory.execute(all, specification, args, registry: context[:registry])
      end

      # Records one journal entry, holding a codec copy of its state, the same as `Memory#append`.
      #
      # @param entry [Ports::Persistence::Entry] the save or delete to journal
      # @return [Ports::Persistence::Entry] the caller's own `entry`, not the journalled copy
      def append(entry)
        copied = Ports::Persistence::Entry.new(operation: entry.operation, id: entry.id,
                                               state: copy(entry.state), mirrors: entry.mirrors)
        @entries << copied
        entry
      end

      # Applies one journaled entry to the current-state store.
      #
      # @param entry [Persistence::Entry] the save or delete to materialize
      # @return [Runtime::Instance, nil] on a save, the newly stored record; on a delete, the
      #   removed record, or nil when no record had that id
      def project(entry)
        if entry.save?
          @records[entry.id] = Runtime::Instance.new(aggregate: @aggregate, id: entry.id, state: copy(entry.state))
        else
          @records.delete(entry.id)
        end
      end

      # Journals and projects an instance's state.
      #
      # @param instance [Runtime::Instance] the record to persist
      # @return [Runtime::Instance] the newly stored record (a copy of `instance`'s state)
      def save(instance)
        entry = Ports::Persistence::Entry.new(operation: "save", id: instance.id.to_s, state: copy(instance.state))
        append(entry)
        project(entry)
      end

      # Writes an entry through an existence check, refusing to replace an existing record
      # when asked.
      #
      # @param entry [Persistence::Entry] the entry to persist (its `id` checked for an
      #   existing record)
      # @param insert_only [Boolean] true to refuse replacing a record that already exists
      # @return [Symbol] `:conflicted` when `insert_only` met an existing record and nothing
      #   was written; `:inserted` or `:replaced` otherwise
      def atomic_put(entry, insert_only: false)
        exists = @records.key?(entry.id.to_s)
        return :conflicted if insert_only && exists

        status = exists ? :replaced : :inserted
        append(entry)
        project(entry)
        status
      end

      # Journals and projects the removal of one record.
      #
      # @param id [String, Object] the record's identity, compared as `id.to_s`
      # @return [Runtime::Instance, nil] the removed record, or nil when no record had that id
      def delete(id)
        entry = Ports::Persistence::Entry.new(operation: "delete", id: id.to_s, state: nil)
        append(entry)
        project(entry)
      end

      # Records one emitted event in this adapter's in-memory event log.
      #
      # @param event [Runtime::Event] the event to record
      # @return [Array<Runtime::Event>] the adapter's in-memory event log, including `event`
      def record_event(event) = @events << event

      # Reads the whole journal, oldest entry first.
      #
      # @return [Array<Persistence::Entry>] a shallow copy of every appended entry
      def entries = @entries.dup

      # Clears the stored records, events and journal so a kept runtime starts clean.
      #
      # @return [LocalStorage] self, so a caller can chain after resetting
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
