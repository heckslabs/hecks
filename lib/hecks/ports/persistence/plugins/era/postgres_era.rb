require "json"

require_relative "../../../../adapters/driven/sql_query_builder"
require_relative "../../../../adapters/driven/postgres/outbox"
require_relative "../../../../adapters/driven/postgres/reconnect"
require_relative "postgres_era/lineage"
require_relative "postgres_era/lineage_manager"
require_relative "postgres_era/events"
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

      attr_reader :aggregate

      # Names the optional persistence capabilities this adapter implements natively.
      #
      # `:cross_process_lock` lets dispatch hold `with_write_lock` instead of the in-process
      # mutex, which `rust/host` in another OS process cannot see (ADR 0036).
      #
      # @return [Array<Symbol>] always `[:atomic_put, :cross_process_lock]`
      def persistence_capabilities = %i[atomic_put cross_process_lock]

      # Declares that this adapter can act on shape drift rather than only refuse.
      #
      # @return [Boolean] always true
      def self.lineage_capable? = true

      # Declares that two tenant boots on separate `schema:` settings keep their tables apart.
      #
      # @return [Boolean] always true
      def self.tenant_capable? = true

      # Resolves this boot's era, minting the next one when the shape drifted and a translation
      # edge covers it. Delegates to `LineageManager.check!`.
      #
      # @param settings [Hash{Symbol, String => Object}] persistence settings; needs `database`
      # @param directory [String, nil] where `HECKS_SCAFFOLD=1` writes a translation edge
      # @return [Integer, nil] the ordinal of the era this boot minted, or nil when none
      # @raise [Runtime::WiringError] if the database is unreachable or the mint refuses
      # @raise [Bluebook::DSL::Malformed] if a held era's text parses under no grammar
      def self.era_check!(registry:, bluebook:, current_text:, settings:, directory: nil)
        LineageManager.check!(
          registry: registry, bluebook: bluebook, current_text: current_text,
          settings: settings, directory: directory
        )
      end

      # Reads one setting under either its Symbol or String spelling.
      #
      # Uses `key?` rather than `||` so a stored `false` is not mistaken for an absent key.
      #
      # @return [Object, nil] the stored value, or `default` when neither spelling is present
      def self.setting(settings, key, default: nil)
        return settings[key] if settings.key?(key)

        str_key = key.to_s
        return settings[str_key] if settings.key?(str_key)

        default
      end

      # Opens a connection to the declared database, selecting the declared `schema` if any.
      # The caller owns the connection and closes it.
      #
      # @param name [String] the domain or aggregate name, used only in refusal messages
      # @param settings [Hash{Symbol, String => Object}] `database` is a name or `postgres://` URL
      # @return [PG::Connection] an open connection
      # @raise [Runtime::WiringError] if `database` is missing or Postgres refuses a statement
      def self.connect_for(name, settings)
        # Lazy so a domain that never wires PostgresEra does not need the pg gem.
        require "pg"

        declared = setting(settings, :database)
        if declared.to_s.empty?
          raise Runtime::WiringError,
                "#{name} binds PostgresEra, which needs a database connection, " \
                "but its world declares no \"database\"."
        end

        connection =
          if declared.start_with?("postgres://", "postgresql://")
            PG.connect(declared)
          else
            PG.connect(dbname: declared)
          end

        # A declared `schema` means the instance is shared; search_path makes every unqualified
        # name this adapter and its lineage classes build resolve inside that schema.
        schema = setting(settings, :schema)
        if schema.to_s != ""
          # Idempotent: the schema may not exist yet on the first boot.
          connection.exec("CREATE SCHEMA IF NOT EXISTS #{connection.quote_ident(schema)}")
          connection.exec("SET search_path TO #{connection.quote_ident(schema)}")
        end

        # Provisioning re-runs CREATE ... IF NOT EXISTS on every boot; silence the notices.
        # Warnings and above still surface.
        connection.exec("SET client_min_messages = warning")
        connection
      rescue PG::Error => e
        raise Runtime::WiringError,
              "cannot bind PostgresEra at #{declared} for #{name}: #{e.message.strip}"
      end

      # Connects and provisions the journal, this aggregate's head and field caches, and the
      # event, saga and outbox tables. Every step is idempotent.
      #
      # @param settings [Hash{Symbol, String => Object}] world settings plus what
      #   `RepositoryFactory.build` merges in: `domain`, `era` and `superseded_by`
      # @raise [Runtime::WiringError] if `database` is missing or the connection is refused
      def initialize(aggregate:, settings: {}, root: nil)
        @aggregate = aggregate
        @settings  = settings
        @db = self.class.connect_for(aggregate.name, settings)
        # Journal name: the owning bluebook's declared name, matching the key rust/host derives its
        # advisory lock from (ADR 0036). A bare aggregate with no owner falls back to its own name.
        @domain = self.class.setting(
          settings, :domain, default: aggregate.hecks_owner&.name || aggregate.storage_name
        ).to_s
        @lineage = Lineage.new(@db, @domain)
        @lineage.ensure_base!
        # Coalesce instead of `setting`: the factory always passes `era:`, nil until the boot gate
        # resolves it, and nil can never be a real override.
        @era = settings.key?(:era) ? settings[:era] : settings["era"]
        @era ||= @lineage.current_era
        # Non-nil only for a held-but-superseded boot. `append` and `atomic_put` refuse on it
        # because a superuser walks through the RLS fence.
        @superseded_by = settings.key?(:superseded_by) ? settings[:superseded_by] : settings["superseded_by"]
        # Idempotent self-healing against any boot-ordering surprise.
        @lineage.ensure_head_snapshot!(table, @era)
        @lineage.ensure_first_head!(table) if @era == 1
        # One row-cache table per where-field the aggregate's queries use; `query` consults it
        # to skip the head reduction.
        @field_caches = ensure_field_caches!
        create_event_table!
        create_saga_table!
        create_outbox_table!
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
        return @db.exec(%(SELECT id, state FROM #{quoted_head} ORDER BY id)).map { |row| instance(row) } unless order_by

        name = order_by.to_s.split(".").first
        unless @aggregate.lifecycle&.field.to_s == name || @aggregate.attribute(name)
          raise Runtime::WiringError,
                "#{@aggregate.name} has no attribute #{order_by.inspect} to order by"
        end

        spec = QuerySpecification::Common::OrderBy.new(field: order_by, direction: direction)
        @db.exec(%(SELECT id, state FROM #{quoted_head} ORDER BY #{order_clause(spec, nil)})).map { |row| instance(row) }
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

      # Appends one entry to the journal and updates the head snapshot and every field cache,
      # all in one transaction under the domain's write lock.
      #
      # The lock precedes the INSERT because the ordinal comes from `nextval()` inside it. It is
      # a different key from `mint_era!`'s, so it serializes writes, never a write against a mint.
      # `project` stays out of it: AppendOnly#recover! already replays it on every boot.
      #
      # @param entry [Ports::Persistence::Entry] the save or delete to journal
      # @return [Ports::Persistence::Entry] the same entry, unchanged
      # @raise [Runtime::WiringError] if this boot's era has been superseded by a mint
      # @raise [PG::Error] if Postgres refuses a statement, such as the era fence's RLS
      def append(entry)
        refuse_superseded_write!
        transaction do
          lock_writes!
          append_and_project!(entry)
        end
        entry
      end

      # Refuses a write from a checkout whose era a later mint has superseded.
      # Runs before the transaction so a stale checkout takes no lock; reads stay allowed.
      #
      # @return [nil] when this boot's era is current
      # @raise [Runtime::WiringError] if the boot gate marked this era superseded
      def refuse_superseded_write!
        return unless @superseded_by

        raise Runtime::WiringError,
              "cannot write #{table} for #{@domain}: this checkout booted era #{@era}, which era " \
              "#{@superseded_by} has superseded — its shape was replaced by a mint, and a write here would " \
              "land in a partition no newer head reads. Reads still work; pull the current bluebook and " \
              "reboot to write again."
      end

      # Saves an entry and reports whether it inserted or replaced, decided under the same lock
      # that guards the write.
      #
      # @param entry [Ports::Persistence::Entry] the save to journal
      # @param insert_only [Boolean] when true, an id already in the head is left untouched
      # @return [Symbol] `:inserted`, `:replaced`, or `:conflicted` when `insert_only` hit a record
      # @raise [Runtime::WiringError] if this boot's era has been superseded by a mint
      # @raise [PG::Error] if Postgres refuses a statement
      def atomic_put(entry, insert_only: false)
        refuse_superseded_write!
        status = nil
        transaction do
          lock_writes!
          exists = !@db.exec_params(
            "SELECT 1 FROM #{quoted_head} WHERE id = $1 LIMIT 1",
            [entry.id.to_s]
          ).ntuples.zero?
          if insert_only && exists
            status = :conflicted
            next
          end
          status = exists ? :replaced : :inserted
          append_and_project!(entry)
        end
        status
      end

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

      # Reads this aggregate's whole journal, every era, in write order. States are decoded but
      # not translated: an ancestor era's row keeps the shape it was written in.
      #
      # @return [Array<Ports::Persistence::Entry>] entries by ascending ordinal
      def entries
        @db.exec_params(
          "SELECT aggregate_id, operation, state, mirrors FROM #{@lineage.quoted_journal} " \
          "WHERE aggregate = $1 ORDER BY ordinal",
          [table]
        ).map do |row|
          state = row["state"] && JSON.parse(row["state"])
          Ports::Persistence::Entry.new(
            operation: row["operation"] || "save",
            id:        row["aggregate_id"],
            state:     Ports::Persistence::StateCodec.decode(@aggregate, state),
            mirrors:   row["mirrors"] && JSON.parse(row["mirrors"])
          )
        end
      end

      # Deletes this aggregate's journal rows, refusing when row-level security turns the DELETE
      # into a silent no-op.
      #
      # The journal forces RLS with no DELETE policy, so an ordinary connection matches zero rows
      # without error; comparing the count before with the DELETE's own count exposes that.
      # Head snapshots, field caches, `events` and saga rows are left as they are.
      #
      # @return [Adapters::PostgresEra] this adapter
      # @raise [Runtime::WiringError] if the journal held rows and the DELETE removed none
      def reset!
        before = @db.exec_params(
          "SELECT count(*) FROM #{@lineage.quoted_journal} WHERE aggregate = $1", [table]
        )[0]["count"].to_i
        result = @db.exec_params("DELETE FROM #{@lineage.quoted_journal} WHERE aggregate = $1", [table])
        if before.positive? && result.cmd_tuples.zero?
          raise Runtime::WiringError,
                "reset! deleted 0 of #{before} row(s) for #{table} in #{@lineage.quoted_journal} — " \
                "FORCE ROW LEVEL SECURITY admits no DELETE policy on the journal, so this connection's " \
                "DELETE silently matched nothing. reset! only works connected as an actual Postgres " \
                "superuser or a role granted BYPASSRLS, not as the provisioner or an app role."
        end
        self
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
      def delete(id)
        entry = Ports::Persistence::Entry.new(operation: "delete", id: id.to_s, state: nil)
        append(entry)
        true
      end

      # Saga rows keep `domain` as a column so domains sharing one schema stay isolated. No lock
      # here: `SagaInterpreter`'s own mutex already serializes in-process writers.

      # Checkpoints one saga instance, replacing the row for the same (domain, process manager,
      # correlation) if one exists.
      #
      # @param memory [Hash] the saga's memory, stored as JSON
      # @param completed_compensations [Array] compensable legs already completed, stored as JSON
      # @return [PG::Result] the upsert's result
      def save_saga(process_manager:, correlation:, state:, memory:, completed_compensations: [])
        @db.exec_params(
          "INSERT INTO hecks_saga_instances (domain, process_manager, correlation, state, memory, completed_compensations) " \
          "VALUES ($1, $2, $3, $4, $5, $6) " \
          "ON CONFLICT (domain, process_manager, correlation) DO UPDATE " \
          "SET state = EXCLUDED.state, memory = EXCLUDED.memory, " \
          "completed_compensations = EXCLUDED.completed_compensations, updated_at = now()",
          [@domain, process_manager.to_s, correlation.to_s, state.to_s, JSON.generate(memory),
           JSON.generate(completed_compensations)]
        )
      end

      # Removes a finished saga instance's checkpoint; a no-op when no such row exists.
      #
      # @return [PG::Result] the DELETE's result
      def delete_saga(process_manager:, correlation:)
        @db.exec_params(
          "DELETE FROM hecks_saga_instances WHERE domain = $1 AND process_manager = $2 AND correlation = $3",
          [@domain, process_manager.to_s, correlation.to_s]
        )
      end

      # Yields every saga checkpoint stored for this domain, so a booting registry can rehydrate.
      #
      # @yieldparam memory [Hash{Symbol => Object}] the saga's memory, keys symbolized
      # @return [Enumerator, PG::Result] an enumerator when no block is given
      def each_saga
        return enum_for(:each_saga) unless block_given?

        @db.exec_params(
          "SELECT process_manager, correlation, state, memory, completed_compensations " \
          "FROM hecks_saga_instances WHERE domain = $1",
          [@domain]
        ).each do |row|
          yield row["process_manager"], row["correlation"], row["state"],
                JSON.parse(row["memory"], symbolize_names: true),
                JSON.parse(row["completed_compensations"] || "[]", symbolize_names: true)
        end
      end

      private

      def lock_writes!
        @db.exec_params(
          "SELECT pg_advisory_xact_lock(hashtext('hecks_ordinal:' || $1))",
          [@lineage.domain]
        )
      end

      def append_and_project!(entry)
        state_json = entry.state && JSON.generate(Ports::Persistence::StateCodec.encode(@aggregate, entry.state))
        ordinal = @db.exec_params(
          "INSERT INTO #{@lineage.quoted_journal} (era, aggregate, aggregate_id, operation, state, mirrors) " \
          "VALUES ($1, $2, $3, $4, $5, $6) RETURNING ordinal",
          [@era, table, entry.id, entry.operation, state_json,
           entry.mirrors && JSON.generate(entry.mirrors)]
        )[0]["ordinal"]

        if entry.save?
          @db.exec_params(
            "INSERT INTO #{quoted_head_snapshot} (id, ordinal, operation, state) VALUES ($1, $2, 'save', $3) " \
            "ON CONFLICT (id) DO UPDATE SET ordinal = EXCLUDED.ordinal, operation = EXCLUDED.operation, " \
            "state = EXCLUDED.state WHERE #{quoted_head_snapshot}.ordinal < EXCLUDED.ordinal",
            [entry.id, ordinal, state_json]
          )
          # Same transaction and ordinal, so every cache is exactly as current as the snapshot.
          @field_caches.each do |field, cache_table|
            @lineage.upsert_field_cache_row!(cache_table, entry.id, ordinal, state_json, query_expression(field))
          end
        else
          # A tombstone row, not a bare DELETE: without one, an ancestor era's saved row would win
          # the head's DISTINCT ON and the deleted record would read back. The ordinal guard keeps
          # a stale replayed delete from clobbering a newer save.
          @db.exec_params(
            "INSERT INTO #{quoted_head_snapshot} (id, ordinal, operation, state) VALUES ($1, $2, 'delete', NULL) " \
            "ON CONFLICT (id) DO UPDATE SET ordinal = EXCLUDED.ordinal, operation = EXCLUDED.operation, " \
            "state = EXCLUDED.state WHERE #{quoted_head_snapshot}.ordinal < EXCLUDED.ordinal",
            [entry.id, ordinal]
          )
          @field_caches.each_value { |cache_table| @lineage.delete_field_cache_row!(cache_table, entry.id) }
        end

        ordinal
      end

      def select_list = "id, state"
      def from_relation = quoted_head
      def dialect_name = "PostgresEra"
      def empty_in_clause = "FALSE"

      def placeholder(binds, value)
        binds << value
        "$#{binds.size}"
      end

      def contains_clause(expression, placeholder)
        "position(#{placeholder} in #{expression}) > 0"
      end

      def list_contains_clause(column, member, placeholder)
        target = member.empty? ? "elem #>> '{}'" : "elem ->> #{text_literal(member)}"
        elements = "jsonb_array_elements(state #> ARRAY[#{text_literal(column)}]::text[]) AS elem"
        "EXISTS (SELECT 1 FROM #{elements} WHERE #{target} = #{placeholder})"
      end

      def plain_column(name) = jsonb_path([name])

      def nested_expression(name, path, member)
        segments = path.empty? ? [name, (member || "value").to_s] : [name, *path]
        jsonb_path(segments)
      end

      def comparable_expression(expression, value)
        value.is_a?(Numeric) ? "(#{expression})::numeric" : expression
      end

      def execute_query(sql, binds)
        @db.exec_params(sql, binds).map { |row| instance(row) }
      end

      def instance(row)
        Runtime::Instance.new(aggregate: @aggregate, id: row["id"], state: decode(row["state"]))
      end

      # Runs after SQL-side era translation, as the last step of every read.
      def decode(state_json)
        Ports::Persistence::StateCodec.decode(@aggregate, JSON.parse(state_json))
      end

      def quote_ident(name) = PG::Connection.quote_ident(name.to_s)
      def quoted_head = quote_ident(@lineage.head_view(table))
      def quoted_head_snapshot = quote_ident(@lineage.head_snapshot(table, @era))

      def order_expression(field)
        expression = query_expression(field)
        numeric_field?(field) ? "(#{expression})::numeric" : expression
      end

      # Postgres defaults to NULLS LAST on ASC; place nulls explicitly (first ascending, last
      # descending) so a declared query answers the same on every adapter.
      def order_clause(order_by, policy)
        direction = order_by.direction.to_s.downcase == "desc" ? "DESC" : "ASC"
        nulls = case policy&.mode.to_s
                when "first" then " NULLS FIRST"
                when "last" then " NULLS LAST"
                else direction == "DESC" ? " NULLS LAST" : " NULLS FIRST"
                end
        "#{order_expression(order_by.field)} #{direction}#{nulls}, id #{direction}"
      end

      # One shared walk decides numericness at any depth, so a nested path is not ordered as text.
      def numeric_field?(field)
        name, *path = field.to_s.split(".")
        QuerySpecification::FieldPath.numeric?(@aggregate.attribute(name), path) do |type|
          Runtime::Value.value_object_for(@aggregate, type)
        end
      end

      # `ARRAY[...]` of escaped literals, never the '{a,b}' syntax: that form has no escaping, so
      # a quote in a segment would become live SQL.
      def jsonb_path(segments)
        "state #>> ARRAY[#{segments.map { |segment| text_literal(segment) }.join(', ')}]::text[]"
      end

      def text_literal(text) = "'#{text.to_s.gsub("'", "''")}'"

      # Where-fields of the aggregate's and its entities' queries that a cache table can represent;
      # order_by-only fields never needed a cache.
      def ensure_field_caches!
        cached_where_fields.to_h do |field|
          [field, @lineage.ensure_field_cache!(table, @era, field, query_expression(field))]
        end
      end

      def cached_where_fields
        fields = declared_queries.flat_map do |q|
          q.wheres.map do |clause|
            clause.field.to_s
          end
        end
        fields.uniq.select { |field| cacheable_field?(field) }
      end

      def declared_queries
        @aggregate.queries + @aggregate.entities.flat_map(&:queries)
      end

      # List fields are excluded: a one-value cache row cannot hold `contains` membership.
      def cacheable_field?(field)
        name = field.to_s.split(".").first
        return true if @aggregate.lifecycle&.field.to_s == name

        attribute = @aggregate.attribute(name)
        !attribute.nil? && !attribute.list?
      end

      # A clause is cache-served when its field has a cache table and it is not a null comparison,
      # which `NullPolicy` intercepts before `where_clause`.
      def cache_eligible?(clause, value)
        @field_caches.key?(clause.field.to_s) &&
          QuerySpecification::Common::NullPolicy.sql_predicate(query_expression(clause.field, value: value), clause.op,
                                                               value).nil?
      end

      # Phase one: candidate ids from the narrow cache tables, INTERSECTed. Reuses `where_clause`
      # against each cache's `value` column, so every operator `super` supports works here.
      def cache_phase(cached)
        binds = []
        clauses = cached.map do |clause, value|
          cache_table = @lineage.field_cache(table, @era, clause.field.to_s)
          "SELECT id FROM #{quote_ident(cache_table)} WHERE #{where_clause(clause.op.to_s, quote_ident('value'), value, binds,
                                                                           field: clause.field)}"
        end
        @db.exec_params(clauses.join("\nINTERSECT\n"), binds).map { |row| row["id"] }
      end

      # Phase two: the head view restricted to phase one's ids plus the clauses it could not
      # accelerate. Repeats the tail of `SqlQueryBuilder#query` so that module stays untouched.
      def head_phase(declared, uncached, ids, args)
        binds = []
        clauses = ["id IN (#{ids.map { |id| placeholder(binds, id) }.join(', ')})"]
        uncached.each do |clause, value|
          expression = query_expression(clause.field, value: value)
          if (null_predicate = QuerySpecification::Common::NullPolicy.sql_predicate(expression, clause.op, value))
            clauses << null_predicate.first
            next
          end
          clauses << where_clause(clause.op.to_s, expression, value, binds, field: clause.field)
        end

        sql = "SELECT #{select_list} FROM #{from_relation} WHERE #{clauses.join(' AND ')}"
        sql << if declared.order_by
                 " ORDER BY #{order_clause(declared.order_by, declared.null_semantics)}"
               else
                 " ORDER BY id"
               end
        sql << " LIMIT #{placeholder(binds, query_value(declared.limit.value, args).to_i)}" if declared.limit
        sql << unbounded_limit if !declared.limit && declared.offset
        sql << " OFFSET #{placeholder(binds, query_value(declared.offset.value, args).to_i)}" if declared.offset
        execute_query(sql, binds)
      end

      def create_saga_table!
        @db.exec(<<~SQL)
          CREATE TABLE IF NOT EXISTS hecks_saga_instances (
            domain               text NOT NULL,
            process_manager      text NOT NULL,
            correlation          text NOT NULL,
            state                text NOT NULL,
            memory               jsonb NOT NULL,
            completed_compensations  jsonb NOT NULL DEFAULT '[]'::jsonb,
            updated_at           timestamptz NOT NULL DEFAULT now(),
            PRIMARY KEY (domain, process_manager, correlation)
          )
        SQL
        # Covers a table created before this column existed, where IF NOT EXISTS is a no-op.
        @db.exec("ALTER TABLE hecks_saga_instances ADD COLUMN IF NOT EXISTS completed_compensations jsonb " \
                 "NOT NULL DEFAULT '[]'::jsonb")
      end
    end
  end
end
