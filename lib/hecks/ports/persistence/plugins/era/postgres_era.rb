require "json"

require_relative "../../../../adapters/driven/sql_query_builder"
require_relative "../../../../adapters/driven/postgres/outbox"
require_relative "../../../../adapters/driven/postgres/reconnect"
require_relative "../../../../adapters/driven/postgres/shared_connection"
require_relative "postgres_era/lineage"
require_relative "postgres_era/lineage_manager"
require_relative "postgres_era/events"
require_relative "postgres_era/class_methods"
require_relative "postgres_era/boot"
require_relative "postgres_era/sagas"
require_relative "postgres_era/journal"
require_relative "postgres_era/dialect"
require_relative "postgres_era/query_phases"
require_relative "postgres_era/head_writes"
require_relative "../../../../ports/persistence/append_only"
require_relative "../../../../query_specification/common/order_by"
require_relative "../../../../runtime/errors"
require_relative "../../../../runtime/event"
require_relative "../../../../runtime/instance"
require_relative "../../../../runtime/registry"

module Hecks
  module Adapters
    # Postgres adapter that journals each write per domain and derives every head by era; the
    # only one that can translate, fork or merge on shape drift. Compare jsonb state canonicalized.
    class PostgresEra
      include SqlQueryBuilder
      include Adapters::PostgresOutbox
      include Adapters::PostgresReconnect
      include Events
      include Sagas
      include Journal
      include Boot
      include Dialect
      include QueryPhases
      include HeadWrites
      extend ClassMethods

      attr_reader :aggregate

      # Names the optional persistence capabilities this adapter implements natively.
      #
      # `:cross_process_lock` lets dispatch hold `with_write_lock` instead of the in-process
      # mutex, which `rust/host` in another OS process cannot see (ADR 0036). `:atomic_append`
      # tells `RepositoryFactory.build` that `append` already commits the snapshot in
      # the same transaction as the journal row, so replaying the journal through `project` on
      # boot has nothing left to fix up.
      #
      # @return [Array<Symbol>] always `[:atomic_put, :cross_process_lock, :atomic_append]`
      def persistence_capabilities = %i[atomic_put cross_process_lock atomic_append]

      # Declares that this adapter can act on shape drift rather than only refuse.
      #
      # @return [Boolean] always true
      def self.lineage_capable? = true

      # Declares that two tenant boots on separate `schema:` settings keep their tables apart.
      #
      # @return [Boolean] always true
      def self.tenant_capable? = true

      # Joins the process's shared connection for the declared database and schema, so every
      # aggregate of a domain runs on one connection, then provisions the journal, this
      # aggregate's head and field caches, and the event, saga and outbox tables. Every step is
      # idempotent.
      #
      # @param settings [Hash{Symbol, String => Object}] world settings plus what
      #   `RepositoryFactory.build` merges in: `domain`, `era` and `superseded_by`
      # @raise [Runtime::WiringError] if `database` is missing or the connection is refused
      def initialize(aggregate:, settings: {}, root: nil)
        @aggregate = aggregate
        @settings  = settings
        @db = PostgresSharedConnection.for(aggregate.name, settings, connector: self.class)
        @domain = journal_domain(aggregate, settings)
        @lineage = Lineage.new(@db, @domain)
        @lineage.ensure_base!
        resolve_era!(settings)
        provision!
      end

      # Names this aggregate in storage: the journal's `aggregate` value and the stem of its
      # head view, head snapshot and field-cache names.
      #
      # @return [String] the aggregate's snake_case storage name
      def table = @aggregate.storage_name

      # Reads one record's current state through the head view, translated to the current shape.
      #
      # @param id [String, Object] the record's identity, compared as `id.to_s`
      # @return [Runtime::Instance, nil] the record, or nil when never written or deleted
      def find(id)
        result = @db.exec_params(%(SELECT id, state FROM #{quoted_head} WHERE id = $1), [id.to_s])
        return nil if result.ntuples.zero?

        instance(result[0])
      end

      # Lists every current record, ordered by id unless the caller names a field.
      #
      # `order_by` is a runtime value (an HTTP param), so it is checked against the aggregate's
      # attributes; an unknown field would otherwise sort by nothing without erroring.
      #
      # @param order_by [String, Symbol, nil] an attribute, the lifecycle field, or a dotted path
      # @param direction [Symbol, String] `desc` sorts descending; nulls sort first ascending
      # @return [Array<Runtime::Instance>] every saved record
      # @raise [Runtime::WiringError] if `order_by` names no attribute of this aggregate
      def all(order_by: nil, direction: :asc)
        return head_instances("ORDER BY id") unless order_by

        refuse_unknown_order_field!(order_by)
        spec = QuerySpecification::Common::OrderBy.new(field: order_by, direction: direction)
        head_instances("ORDER BY #{order_clause(spec, nil)}")
      end

      # Counts current records in SQL against the head view, without loading any state.
      #
      # @return [Integer] how many saved, undeleted records the head holds
      def count = @db.exec(%(SELECT COUNT(*) FROM #{quoted_head}))[0]["count"].to_i

      # Runs a declared query, looking candidate ids up in the field caches when every `where`
      # clause allows it and only then reading those ids from the head view.
      #
      # The cache only narrows candidates; the head view stays authoritative, so results match
      # `super`. Uncached or null-comparison clauses are re-checked against the head view.
      #
      # @param declared [Bluebook::Query] the declared query, or a delegator wrapping one
      # @param args [Hash{Symbol => Object}] caller-supplied values for named arguments
      # @return [Array<Runtime::Instance>] the matching records, by id when no order is declared
      # @raise [ArgumentError] if a clause uses an operator this dialect cannot compile
      def query(declared, args = {}, context: {})
        return super if @field_caches.empty? || declared.wheres.empty?

        evaluated = declared.wheres.map { |clause| [clause, query_value(clause.value, args)] }
        cached, uncached = evaluated.partition { |clause, value| cache_eligible?(clause, value) }
        return super if cached.empty?

        ids = cache_phase(cached)
        return [] if ids.empty?

        head_phase(declared, uncached, ids, args)
      end

      # Runs a block in one transaction holding the domain's cross-process write lock (ADR 0036).
      #
      # The lock must be taken before hydrate, so it wraps the whole dispatch order; the
      # nested `append` joins this transaction and the lock is held until the block returns.
      #
      # @yield the dispatch order; an exception rolls the transaction back
      # @return [Object] the block's own value
      # @raise [PG::ConnectionBad] if the connection dropped; it reconnects, then re-raises
      def with_write_lock(&block) = transaction { lock_writes!; block.call } # rubocop:disable Style/Semicolon

      # Builds the instance an entry describes, writing nothing; the head is derived, so
      # projecting is reading.
      #
      # @param entry [Ports::Persistence::Entry] a journaled save or delete
      # @return [Runtime::Instance, nil] the saved record, or nil for a delete entry
      # @raise [Runtime::WiringError] if the entry's state is still in its stored form
      def project(entry)
        return if entry.delete?

        Runtime::Instance.new(aggregate: @aggregate, id: entry.id, state: entry.state)
      end

      # Journals an instance's current state as a save entry. A direct-adapter convenience for
      # specs and consoles; a runtime saves through `Ports::Persistence::AppendOnly`.
      #
      # @param instance [Runtime::Instance] the record to persist
      # @return [Runtime::Instance] a fresh instance built from the journaled state
      # @raise [Runtime::WiringError] if this boot's era has been superseded by a mint
      def save(instance)
        entry = Ports::Persistence::Entry.new(operation: "save", id: instance.id.to_s, state: instance.state.dup)
        append(entry)
        project(entry)
      end

      # Journals a delete entry and tombstones the id in the head snapshot, without checking
      # that the record exists.
      #
      # @param id [String, Object] the record's identity, journaled as `id.to_s`
      # @return [true] always
      # @raise [Runtime::WiringError] if this boot's era has been superseded by a mint
      def delete(id) # rubocop:disable Naming/PredicateMethod -- the repository port's verb, not a question
        entry = Ports::Persistence::Entry.new(operation: "delete", id: id.to_s, state: nil)
        append(entry)
        true
      end

      private

      def refuse_unknown_order_field!(order_by)
        name = order_by.to_s.split(".").first
        return if @aggregate.lifecycle&.field.to_s == name || @aggregate.attribute(name)

        raise Runtime::WiringError,
              "#{@aggregate.name} has no attribute #{order_by.inspect} to order by"
      end
    end
  end
end
