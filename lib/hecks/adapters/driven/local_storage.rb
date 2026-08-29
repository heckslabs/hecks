require_relative "../../ports/persistence/append_only"
require_relative "../../ports/query/in_memory"
require_relative "in_memory_ordering"
require_relative "../../runtime/instance"

module Hecks
  module Adapters
    # A BROWSER-HOSTED DOMAIN'S OWN DECLARED INTENT — not a second Memory
    # wearing a different name. Ruby has no way to reach a real browser's
    # `window.localStorage` at all (it is per-tab, per-origin, JS-only,
    # unreachable over any network the way D1's own REST API is) — so
    # this Ruby-side adapter is honestly a stand-in: in-process, ephemeral,
    # mechanically identical to Memory. What earns it a name of its own
    # is what it DECLARES, not what it happens to do in Ruby: `persisted_by
    # "LocalStorage"` says "this domain expects real, durable, single-
    # device storage the moment it's actually running where it's meant to
    # run" — the same distinction Heki (real local durability) already
    # draws against Memory (deliberately ephemeral, test/example-only),
    # one adapter over. `bin/console`, the fuzzer, `spec/`, `bin/
    # model_check` all get a domain that boots and behaves correctly
    # against this adapter; only a real browser gets the real durability.
    #
    # THE REAL BROWSER HALF lives outside this file entirely: `rust/web`'s
    # `dispatch(json)` (docs/implemented/decisions/0015) takes an optional
    # `"seed"` (the exact `"instances"` shape it also answers with) plus
    # `"steps"` — a host rehydrates from a prior snapshot and replays only
    # the new command(s), rather than the whole history every call. A
    # page bound to this adapter is expected to hold that snapshot in
    # `window.localStorage` itself (get on load, set after every
    # `dispatch`) — the seed/instances round trip IS the adapter, once
    # you're in the one runtime that can actually reach the storage this
    # name promises.
    class LocalStorage
      # TENANT-CAPABLE TRIVIALLY, same reasoning as Memory's own — a
      # browser tab is exactly one origin, exactly one user; there is no
      # second tenant this in-process Hash could ever confuse a first
      # one with.
      def self.tenant_capable? = true
      def persistence_capabilities = [:atomic_put]

      attr_reader :aggregate, :events

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

      # THE DECISION THE GUIDE ASKS FOR, MADE EXPLICITLY: no compiled
      # dialect of its own, same as Heki/Memory — a personal-scale local
      # store answering by walking `all` is correct on day one, and
      # nothing about a browser tab's own data volume asks for pushdown.
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

      def reset!
        @records = {}
        @events  = []
        @entries = []
        self
      end

      # NOT lineage_capable? — deliberately absent, the same trade Heki
      # makes and states plainly (writing-an-adapter.md's own section on
      # it): a domain bound here has no edge for its own shape to travel
      # across if it ever changes; that must be hand-migrated, or the
      # shape must not change. A browser-local personal store is exactly
      # the small-adapter case that guide names as a fine place to make
      # that trade.
    end
  end
end
