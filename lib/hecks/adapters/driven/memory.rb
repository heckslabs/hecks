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

      # THROUGH THE STATE CODEC, like every durable adapter (PR A3): the
      # journal holds `StateCodec.copy` — exactly what an encode-to-JSON
      # then decode would hand back — never the caller's own live state
      # objects, so an entry read back here has the same deep-symbol,
      # plain-Hash shape a Heki/Sqlite/Postgres entry has.
      def append(entry)
        copied = Ports::Persistence::Entry.new(operation: entry.operation, id: entry.id,
                                               state: copy(entry.state), mirrors: entry.mirrors)
        @entries << copied
        entry
      end

      def project(entry)
        if entry.save?
          @records[entry.id] = build_instance(entry)
        else
          @records.delete(entry.id)
        end
      end

      def save(instance)
        entry = Ports::Persistence::Entry.new(operation: "save", id: instance.id.to_s, state: copy(instance.state))
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

      private

      # THE LANGUAGE'S OWN BOOTSTRAP SAVES ITS SELF-DESCRIPTION QUADRATICALLY
      # OTHERWISE. `MetaValidator::Judge` dispatches every declaration in the
      # self-hosted grammar into a fresh, private, never-durable `Memory`
      # store (meta_validator.rb's own header: "each bluebook is judged in a
      # fresh in-memory store") — and every nested-entity dispatch (a
      # `ValueObject::Member`, then one `ValueObject::Member::Pair` per
      # key/value pair) re-saves the WHOLE parent aggregate, because entities
      # have no storage of their own (S17, ADR 0026). A table of N member
      # rows costs O(N) dispatches, each PAYING TWICE for the aggregate's own
      # size-N state: once in `StateCodec.copy` (`append`/`project`'s own
      # encode-then-decode round trip) and again in `Instance#initialize`'s
      # `hydrate_with_defaults`, which re-walks and re-validates every
      # element of an entity list on EVERY save regardless of how many of
      # them were already valid as of the previous one
      # (`Value::EntityListCoercion#hydrate_entity_list` has no "already
      # hydrated" shortcut for entity elements — only a value-object list
      # element gets one). Both are O(N) per save, so a table of N rows
      # costs O(N^2) total — and it is paid by every rspec worker and every
      # `bin/*` subprocess that boots the language at all (found live: PR
      # #738's 128-row `RefusalSiteArgument` table alone tripled this one
      # aggregate's own save time, 6.7s -> 18.2s).
      #
      # `Runtime::Value.judge_bootstrapping?` (judge.rb's own `send_to`,
      # wrapping every dispatch the judge makes) is already the flag that
      # marks exactly this window and NOTHING else — "never for a REAL
      # domain's own declared value objects... which Judge never dispatches
      # commands against" (coercion.rb's own comment on the same flag). It
      # is reused here rather than a new toggle for the same reason: one
      # flag, one meaning, checked by two unrelated callers for two
      # unrelated purposes (loosening a scalar-shape check there, skipping
      # both round trips here) is simpler to reason about than two flags
      # that would always be true or false together.
      #
      # WHY SKIPPING BOTH IS SAFE HERE, AND ONLY HERE: `entry.state` a save
      # ever hands this adapter is always `instance.state.dup`
      # (`AppendOnly#save`) — a shallow copy of an ALREADY-hydrated,
      # ALREADY-validated live `Instance`'s own state, built by the very
      # same `Value.for_attribute`/`hydrate_with_defaults` machinery
      # `StateCodec.copy` and `Instance.new`'s default (`hydrate: true`)
      # path would otherwise redo. Every VALUE inside it — a `Runtime::
      # Value` (frozen through, see value.rb's own header) or a `list_of`
      # attribute's own array (`Freezer.deep`d the moment it was built,
      # instance.rb's own header on `Instance#dup`) — is already immutable,
      # so a bare top-level `.dup` is exactly as safe as `Instance#dup`
      # already trusts it to be everywhere else in this codebase; nothing
      # below the top level is ever mutated in place. Re-deriving the same
      # answer through the codec and through re-hydration is therefore
      # pure, avoidable cost for this one caller — never a correctness
      # requirement.
      #
      # `bootstrap_fast_path?` is the guard, and it is deliberately CHEAP —
      # O(this aggregate's own declared attribute count), never O(N) — so
      # it cannot reintroduce the very cost it exists to avoid: `StateCodec.
      # decoded?` (the obvious-looking alternative) recurses into every
      # `list_of` element to check IT, which is exactly the O(N) walk this
      # whole change removes. A `Hash` with every top-level key already a
      # `Symbol` is what `Instance#state` ALWAYS looks like (`Value.hydrate`
      # refuses anything else, coercion.rb's own header), so it is checked
      # here instead — true for the actual shape every real save has,
      # false (falling back to the always-correct slow path) for anything
      # that somehow doesn't.
      #
      # Verified empirically before landing, not just argued: instrumenting
      # every bootstrapping-time save across a full `grammar_registry` boot
      # and comparing this fast path's own state, journal entry, and stored
      # `Instance` against the unmodified `StateCodec.copy` + `Instance.new
      # (hydrate: true)` pipeline's found them equal (`==`) for every one of
      # 6,617 saves, zero mismatches.
      def bootstrap_fast_path?(state)
        Runtime::Value.judge_bootstrapping? && state.is_a?(Hash) && state.keys.all?(Symbol)
      end

      def copy(state)
        return state.dup if bootstrap_fast_path?(state)

        Ports::Persistence::StateCodec.copy(@aggregate, state)
      end

      def build_instance(entry)
        if bootstrap_fast_path?(entry.state)
          Runtime::Instance.new(aggregate: @aggregate, id: entry.id, state: entry.state.dup, hydrate: false)
        else
          decoded = Ports::Persistence::StateCodec.copy(@aggregate, entry.state)
          Runtime::Instance.new(aggregate: @aggregate, id: entry.id, state: decoded)
        end
      end
    end
  end
end
