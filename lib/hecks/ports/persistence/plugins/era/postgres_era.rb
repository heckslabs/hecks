require "json"

require_relative "../../../../adapters/driven/sql_query_builder"
require_relative "postgres_era/lineage"
require_relative "postgres_era/lineage_manager"
require_relative "../../../../ports/persistence/append_only"
require_relative "../../../../query_specification/common/order_by"
require_relative "../../../../runtime/errors"
require_relative "../../../../runtime/event"
require_relative "../../../../runtime/instance"
require_relative "../../../../runtime/registry"

module Hecks
  module Adapters
    # The enforcement-grade persistence adapter — and the only one that
    # declares the LINEAGE capability: it may act on shape drift
    # (translate, fork, merge) where every other adapter can only refuse
    # toward it. Sibling to the plain `Postgres` adapter (postgres.rb),
    # which is the same database with none of this machinery — pick
    # PostgresEra only once a domain actually needs to survive a shape
    # change live. See docs/implemented/postgres-era-adapter-split-plan.md for why
    # the two are split and what each one carries.
    #
    # Storage model (see postgres_era/lineage.rb for the DDL):
    # - One journal per DOMAIN, list-partitioned by era, one ordinal
    #   sequence spanning partitions. Appends go there; nothing updates
    #   or deletes a journal row (immutability by privilege — UPDATE and
    #   DELETE revoked; a deployment's app role connects as a non-owner).
    # - Per aggregate, the HEAD is derived: era 1 reads a plain view
    #   (latest save per id); later eras read a view overlaying the
    #   materialized, translated ancestor tail with live current-era
    #   rows. `project` is therefore a no-op — old entries are never
    #   rewritten, and the head is never a table anything writes.
    # - State is ONE jsonb column. jsonb normalizes key order (and drops
    #   duplicate keys), so anything comparing stored state — the corpus
    #   history gate above all — must compare CANONICALIZED state, never
    #   raw bytes; `bin/canonicalise` deep-sorts keys, which is exactly
    #   why the gate survives this normalization.
    # - Query pushdown is the shared SqlQueryBuilder: every declared
    #   operator compiles fully into SQL, or the query refuses loudly.
    class PostgresEra
      include SqlQueryBuilder

      attr_reader :aggregate

      def persistence_capabilities = [:atomic_put]

      # The capability idiom: only PostgresEra answers true, and only
      # PostgresEra carries an era_check! for the boot gate to delegate to.
      def self.lineage_capable? = true

      # TENANT-CAPABLE — see Runtime::TenantCheck's own header for the
      # full reasoning. `connect_for`'s own `schema:` setting (the
      # Storehouse shared-instance mechanism, already built, already
      # proven for eras) is what keeps two tenant boots' tables apart:
      # each boot's own `SET search_path` means every unqualified
      # reference this adapter and its lineage classes construct
      # resolves into that boot's own schema, never another tenant's —
      # proven for real, not assumed, by tenant_isolation_spec.rb, the
      # same discipline lineage_capable? already holds itself to.
      def self.tenant_capable? = true

      def self.era_check!(registry:, bluebook:, current_text:, settings:, directory: nil)
        LineageManager.check!(
          registry: registry, bluebook: bluebook, current_text: current_text,
          settings: settings, directory: directory
        )
      end

      def self.connect_for(name, settings)
        # LAZY, ON PURPOSE — same reasoning as Sqlite's own initialize:
        # a domain that never wires PostgresEra should never need the gem.
        require "pg"

        declared = settings[:database] || settings["database"]
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

        # SHARED-INSTANCE ISOLATION. A domain that declares `schema` is
        # sharing its Postgres instance with other domains (the
        # storehouse) — every unqualified table/view/function reference
        # this adapter and its lineage classes ever construct resolves
        # through search_path, so this one SET is what makes ALTER
        # TABLE ... SET SCHEMA migrations transparent to the rest of the
        # adapter. A domain with no `schema` setting keeps Postgres's
        # own default search_path (public), same as before this existed.
        schema = settings[:schema] || settings["schema"]
        if schema.to_s != ""
          # THE SCHEMA ITSELF, IDEMPOTENTLY — a domain naming a `schema:`
          # nobody has created yet used to fail on its FIRST table-
          # creation attempt with Postgres's own "no schema has been
          # selected to create in", found live provisioning tenant_
          # isolation_spec.rb's own multi-schema fixture by hand before
          # this existed. `CREATE SCHEMA IF NOT EXISTS` is exactly the
          # same self-healing idempotency this adapter's own table/era
          # provisioning already holds itself to (see the comment right
          # below on `client_min_messages`) — a schema that already
          # exists is the ORDINARY case for every boot after the first,
          # not news.
          connection.exec("CREATE SCHEMA IF NOT EXISTS #{connection.quote_ident(schema)}")
          connection.exec("SET search_path TO #{connection.quote_ident(schema)}")
        end

        # QUIET ON PURPOSE. Provisioning re-runs its own idempotent
        # `CREATE ... IF NOT EXISTS` checks on every boot — a schema that
        # already exists is the ORDINARY case, not news, and Postgres
        # surfaces every one as a NOTICE by default. `bin/set-password`
        # boots a real registry just to mint an Identity, and nobody
        # setting a password needs to see a page of "relation ...
        # already exists, skipping" to do it. WARNING and above (real
        # problems) still surface.
        connection.exec("SET client_min_messages = warning")
        connection
      rescue PG::Error => error
        raise Runtime::WiringError,
              "cannot bind PostgresEra at #{declared} for #{name}: #{error.message.strip}"
      end

      def initialize(aggregate:, settings: {}, root: nil)
        @aggregate = aggregate
        @db = self.class.connect_for(aggregate.name, settings)
        # The domain names the journal (one journal per lineage). The
        # factory injects it; a directly-instantiated adapter (specs,
        # consoles) journals under the aggregate's own name.
        @domain = (settings[:domain] || settings["domain"] || aggregate.storage_name).to_s
        @lineage = Lineage.new(@db, @domain)
        @lineage.ensure_base!
        # The era gate resolves which era this boot IS (an old checkout
        # boots a held-but-superseded era and keeps writing its own
        # partition); a directly-instantiated adapter defaults to the
        # newest.
        @era = settings[:era] || settings["era"] || @lineage.current_era
        # Unconditional and idempotent, regardless of era — belt-and-
        # suspenders self-healing (compile_head! already ensures this for
        # a freshly-minted era's own name; ensure_first_head! for era 1's)
        # against any boot-ordering surprise, at the cost of one
        # CREATE TABLE IF NOT EXISTS nobody pays for twice.
        @lineage.ensure_head_snapshot!(table, @era)
        @lineage.ensure_first_head!(table) if @era == 1
        # THE READ-CACHE SIDE OF THE ERA WORKAROUND (Track C,
        # docs/implemented/postgres-era-adapter-split-plan.md §3) — one row-cache
        # table per `where`-field this aggregate's own declared queries
        # (and its entities' own) actually use, derived automatically
        # (principle 3 — no bluebook keyword), self-healing and
        # idempotent like everything else booted here. `@field_caches`
        # maps field -> cache-table name; `query` below consults it to
        # decide whether a declared query can skip the DISTINCT ON
        # reduction entirely.
        @field_caches = ensure_field_caches!
        create_event_table!
        create_saga_table!
      end

      def table = @aggregate.storage_name

      def find(id)
        result = @db.exec_params(%(SELECT id, state FROM #{quoted_head} WHERE id = $1), [id.to_s])
        return nil if result.ntuples.zero?

        instance(result[0])
      end

      # order_by IS A RUNTIME VALUE, not framework-authored bluebook source
      # like every other caller of order_expression — a query param off an
      # HTTP request, in the console's case. Whitelisted against the
      # aggregate's own real attributes (plus its lifecycle field) before
      # it ever reaches order_expression, unlike a declared query's
      # order_by, which the language itself already only lets name a real
      # attribute at parse time. Without this, an unknown field wouldn't
      # error — query_expression degrades a nil attribute to a harmless
      # no-op path — it would just silently sort by nothing.
      def all(order_by: nil, direction: :asc)
        return @db.exec(%(SELECT id, state FROM #{quoted_head} ORDER BY id)).map { |row| instance(row) } unless order_by

        name = order_by.to_s.split(".").first
        raise Runtime::WiringError, "#{@aggregate.name} has no attribute #{order_by.inspect} to order by" unless @aggregate.lifecycle&.field.to_s == name || @aggregate.attribute(name)

        spec = QuerySpecification::Common::OrderBy.new(field: order_by, direction: direction)
        @db.exec(%(SELECT id, state FROM #{quoted_head} ORDER BY #{order_clause(spec, nil)})).map { |row| instance(row) }
      end

      def count = @db.exec(%(SELECT COUNT(*) FROM #{quoted_head}))[0]["count"].to_i

      # THE TWO-PHASE SHORTCUT (Track C, docs/implemented/postgres-era-adapter-
      # split-plan.md §3). `SqlQueryBuilder#query` (`super`, unmodified per
      # principle 2) always runs correctly here — it filters against
      # `head_view`, which is already the fully-reduced current state —
      # but for a domain that has minted a second era, that reduction
      # itself is the expensive part, and no index on the jsonb path
      # changes that (see field_cache.rb's own header for the SQL-
      # semantics reason why). When every `where` clause this query
      # declares either targets a cached field or is eligible to (an
      # ordinary comparator, not a null-vs-value special case — see
      # `cache_eligible?`), skip the reduction: look candidate ids up in
      # the cache table(s) first (cheap, indexed, no reduction involved),
      # then read ONLY those ids' current state from `head_view` — safe
      # THROUGH the reduction because `id` is its own partition key. Any
      # clause that ISN'T cache-eligible (an uncached field, or a null
      # comparison) is simply re-checked against `head_view` in the
      # second phase, exactly as `super` would have checked it anyway —
      # this can only ever NARROW what phase two has to look at, never
      # change what a clause means.
      #
      # FALLS BACK TO `super` WHENEVER NO CLAUSE CAN BE ACCELERATED — a
      # query with no `where` at all (order_by-only — no cache table
      # exists for these, see field_cache.rb), a query whose only clauses
      # target fields with no cache table, or a domain that has never
      # minted a second era at all (`@field_caches` is never empty just
      # because era 1 has no reduction to skip — the cache tables still
      # exist and still accelerate era 1 the same way, but the fallback
      # path is already just as cheap there since head_view IS the
      # snapshot table verbatim for era 1; skipping straight to `super`
      # in that case would be a valid FUTURE optimization, not attempted
      # here to keep this one code path correct for every era uniformly).
      def query(declared, args = {}, context: {})
        return super if @field_caches.empty? || declared.wheres.empty?

        evaluated = declared.wheres.map { |clause| [clause, query_value(clause.value, args)] }
        cached, uncached = evaluated.partition { |clause, value| cache_eligible?(clause, value) }
        return super if cached.empty?

        ids = cache_phase(cached)
        return [] if ids.empty?

        head_phase(declared, uncached, ids, args)
      end

      # HELD FOR THE WHOLE TRANSACTION, not just around the INSERT — the
      # ordinal is assigned by the column's own `nextval()` default, inside
      # this same statement, so the lock has to already be held before that
      # default evaluates. A DIFFERENT key from `mint_era!`/`merge_tail!`'s
      # `hecks_eras:domain` : this serializes plain writes against EACH
      # OTHER, never against a mint. See postgres/lineage.rb's own comment
      # for why only that half of the race is closed.
      # The journal insert and the snapshot upsert/delete happen in the
      # SAME transaction — real ACID atomicity, not the append-then-
      # project two-step a file-based adapter needs a crash-recovery
      # replay for (see Heki). If this transaction commits, the snapshot
      # is already exactly as current as the journal; if it doesn't,
      # neither happened. `project` stays uninvolved on purpose — it
      # still runs, cheaply, during AppendOnly#recover!'s full replay on
      # every boot (see `project` below), and a second write there would
      # make that replay pay real DB cost for a snapshot that's already
      # correct.
      def append(entry)
        @db.transaction do
          lock_writes!
          append_and_project!(entry)
        end
        entry
      end

      # Outcome detection, journal append and every derived projection share
      # the SAME transaction and domain write lock. The lineage-aware head
      # determines whether this id is already visible; no repository `find`
      # occurs before entering this adapter-native operation.
      def atomic_put(entry, insert_only: false)
        status = nil
        @db.transaction do
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

      # The head is DERIVED — projecting is reading, so there is nothing
      # to write here. `append` above already keeps the snapshot the head
      # view reads from current, transactionally. The instance is still
      # built (and validated) so a save returns what every other adapter
      # returns.
      def project(entry)
        return if entry.delete?

        Runtime::Instance.new(aggregate: @aggregate, id: entry.id, state: entry.state)
      end

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
            state:     state&.transform_keys(&:to_sym),
            mirrors:   row["mirrors"] && JSON.parse(row["mirrors"])
          )
        end
      end

      def reset!
        @db.exec_params("DELETE FROM #{@lineage.quoted_journal} WHERE aggregate = $1", [table])
        self
      end

      def save(instance)
        entry = Ports::Persistence::Entry.new(operation: "save", id: instance.id.to_s, state: instance.state.dup)
        append(entry)
        project(entry)
      end

      def delete(id)
        entry = Ports::Persistence::Entry.new(operation: "delete", id: id.to_s, state: nil)
        append(entry)
        true
      end

      def record_event(event)
        @db.exec_params(
          "INSERT INTO events (name, aggregate, aggregate_id, payload, occurred_at) VALUES ($1, $2, $3, $4, $5)",
          [event.name, event.aggregate, event.id.to_s, JSON.generate(event.payload), event.occurred_at]
        )
      end

      def events
        @db.exec("SELECT * FROM events ORDER BY id").map do |row|
          Runtime::Event.new(
            name:        row["name"],
            aggregate:   row["aggregate"],
            id:          row["aggregate_id"],
            payload:     JSON.parse(row["payload"], symbolize_names: true),
            occurred_at: row["occurred_at"]
          )
        end
      end

      # ── the OPTIONAL saga-persistence capability (Ports::Persistence's
      # own three-method shape, §2) — one row per (domain, process_manager,
      # correlation), `domain` kept as an explicit column even under
      # schema isolation so two domains sharing one schema (neither
      # declares its own `schema`) still isolate correctly, matching
      # `hecks_eras`' own precedent (postgres/lineage/provisioning.rb).
      # No advisory lock of its own: every call here already runs inside
      # `SagaInterpreter`'s own mutex (§7) serializing IN-PROCESS writers,
      # and gets the SAME cross-process safety an aggregate's own writes
      # get from this adapter — no better, no worse.
      def save_saga(process_manager:, correlation:, state:, memory:)
        @db.exec_params(
          "INSERT INTO hecks_saga_instances (domain, process_manager, correlation, state, memory) " \
          "VALUES ($1, $2, $3, $4, $5) " \
          "ON CONFLICT (domain, process_manager, correlation) DO UPDATE " \
          "SET state = EXCLUDED.state, memory = EXCLUDED.memory, updated_at = now()",
          [@domain, process_manager.to_s, correlation.to_s, state.to_s, JSON.generate(memory)]
        )
      end

      def delete_saga(process_manager:, correlation:)
        @db.exec_params(
          "DELETE FROM hecks_saga_instances WHERE domain = $1 AND process_manager = $2 AND correlation = $3",
          [@domain, process_manager.to_s, correlation.to_s]
        )
      end

      def each_saga
        return enum_for(:each_saga) unless block_given?

        @db.exec_params(
          "SELECT process_manager, correlation, state, memory FROM hecks_saga_instances WHERE domain = $1",
          [@domain]
        ).each do |row|
          yield row["process_manager"], row["correlation"], row["state"],
                JSON.parse(row["memory"], symbolize_names: true)
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
        state_json = entry.state && JSON.generate(entry.state)
        ordinal = @db.exec_params(
          "INSERT INTO #{@lineage.quoted_journal} (era, aggregate, aggregate_id, operation, state, mirrors) " \
          "VALUES ($1, $2, $3, $4, $5, $6) RETURNING ordinal",
          [@era, table, entry.id, entry.operation, state_json,
           entry.mirrors && JSON.generate(entry.mirrors)]
        )[0]["ordinal"]

        if entry.save?
          @db.exec_params(
            "INSERT INTO #{quoted_head_snapshot} (id, ordinal, state) VALUES ($1, $2, $3) " \
            "ON CONFLICT (id) DO UPDATE SET ordinal = EXCLUDED.ordinal, state = EXCLUDED.state " \
            "WHERE #{quoted_head_snapshot}.ordinal < EXCLUDED.ordinal",
            [entry.id, ordinal, state_json]
          )
          # SAME TRANSACTION, SAME ORDINAL — every field cache stays
          # exactly as current as the snapshot it's derived from, for
          # the identical reason `postgres_era.rb`'s own header comment
          # gives for the journal/snapshot pair: if this transaction
          # commits, every cache row is already correct; if it doesn't,
          # none of them changed.
          @field_caches.each do |field, cache_table|
            @lineage.upsert_field_cache_row!(cache_table, entry.id, ordinal, state_json, query_expression(field))
          end
        else
          @db.exec_params("DELETE FROM #{quoted_head_snapshot} WHERE id = $1", [entry.id])
          @field_caches.each_value { |cache_table| @lineage.delete_field_cache_row!(cache_table, entry.id) }
        end

        ordinal
      end

      # ── SqlQueryBuilder's dialect hooks ─────────────────────────────

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

      # ── the rest of the dialect ─────────────────────────────────────

      def instance(row)
        Runtime::Instance.new(aggregate: @aggregate, id: row["id"], state: decode(row["state"]))
      end

      def decode(state_json)
        # Deep symbols, exactly what the Sqlite adapter's per-column
        # `symbolize_names:` decode produces — value-object members and
        # list elements arrive symbol-keyed either way.
        JSON.parse(state_json, symbolize_names: true)
      end

      def quote_ident(name) = PG::Connection.quote_ident(name.to_s)
      def quoted_head = quote_ident(@lineage.head_view(table))
      def quoted_head_snapshot = quote_ident(@lineage.head_snapshot(table, @era))

      def order_expression(field)
        expression = query_expression(field)
        numeric_field?(field) ? "(#{expression})::numeric" : expression
      end

      # Postgres defaults to NULLS LAST on ASC; the port's in-memory
      # semantics (NullPolicy.order, which SQLite's own default happens
      # to match) put null rows FIRST ascending and LAST
      # descending. Compile the placement explicitly so a declared query
      # answers identically no matter which adapter serves it.
      def order_clause(order_by, policy)
        direction = order_by.direction.to_s.downcase == "desc" ? "DESC" : "ASC"
        nulls = case policy&.mode.to_s
                when "first" then " NULLS FIRST"
                when "last" then " NULLS LAST"
                else direction == "DESC" ? " NULLS LAST" : " NULLS FIRST"
                end
        "#{order_expression(order_by.field)} #{direction}#{nulls}, id #{direction}"
      end

      # One shared walk decides numericness at ANY depth — this used to
      # inspect only the first nested segment, so a two-level path
      # (pizza.price_cents.cents) skipped the ::numeric cast and ordered
      # as text: "900" above "1200".
      def numeric_field?(field)
        name, *path = field.to_s.split(".")
        QuerySpecification::FieldPath.numeric?(@aggregate.attribute(name), path) do |type|
          @aggregate.value_object(type)
        end
      end

      # ARRAY[...] of individually-escaped literals, never the hand-rolled
      # '{a,b,c}' array-literal SYNTAX — a segment is a field or
      # value-object member name, and while today's callers only ever
      # pass schema-declared names, this method has no way to know
      # that, and the '{...}' form has no escaping at all: a segment
      # containing a single quote closes the string early and whatever
      # follows becomes live SQL. Measured, not assumed — a crafted
      # field name of `x}' = '' OR $1::text = $1::text -- ` made a
      # `where(secret: "public")` clause return every row regardless,
      # against the OLD form; the ARRAY[] form below closes it, verified
      # against the identical payload.
      def jsonb_path(segments)
        "state #>> ARRAY[#{segments.map { |segment| text_literal(segment) }.join(', ')}]::text[]"
      end

      def text_literal(text) = "'#{text.to_s.gsub("'", "''")}'"

      # ── the field-cache read shortcut (Track C) ─────────────────────

      # EVERY declared `where`-field this aggregate's own queries and its
      # entities' own queries use, minus anything a cache table can't
      # represent (see `cacheable_field?`) — never `order_by`-only
      # fields, which never needed a cache in the first place (sorting
      # the reduced output was never blocked by the reduction; only
      # filtering was — see field_cache.rb's own header).
      def ensure_field_caches!
        cached_where_fields.to_h do |field|
          [field, @lineage.ensure_field_cache!(table, @era, field, query_expression(field))]
        end
      end

      def cached_where_fields
        declared_queries.flat_map { |q|
          q.wheres.map { |clause|
            clause.field.to_s
          }
        }.uniq.select { |field| cacheable_field?(field) }
      end

      def declared_queries
        @aggregate.queries + @aggregate.entities.flat_map(&:queries)
      end

      # LIST-TYPED FIELDS ARE EXCLUDED, same boundary the plain `Postgres`
      # and `Sqlite`/`D1` adapters independently landed on for their own
      # automatic indexing: `contains` means element membership, and a
      # (id, ordinal, ONE value) cache row has nowhere to put more than
      # one element. Everything else — a plain scalar, the lifecycle
      # field, or a non-list value-object member path — reduces to
      # exactly one comparable value per id, which is the one shape this
      # cache table represents.
      def cacheable_field?(field)
        name = field.to_s.split(".").first
        return true if @aggregate.lifecycle&.field.to_s == name

        attribute = @aggregate.attribute(name)
        !attribute.nil? && !attribute.list?
      end

      # A clause can be served by the cache when its field has a cache
      # table AND it isn't the null-vs-value special case
      # `QuerySpecification::Common::NullPolicy` intercepts before
      # `where_clause` ever runs (see `query`'s own header comment) — a
      # clause that fails either check simply flows to `head_phase`
      # unaccelerated, exactly as `super` would have evaluated it.
      def cache_eligible?(clause, value)
        @field_caches.key?(clause.field.to_s) &&
          QuerySpecification::Common::NullPolicy.sql_predicate(query_expression(clause.field, value: value), clause.op,
                                                               value).nil?
      end

      # PHASE ONE — candidate ids, no reduction touched. One SELECT per
      # cached clause against its own narrow (id, ordinal, value) table,
      # `INTERSECT`ed into the set that satisfies every cached clause at
      # once. Reuses `where_clause` (SqlQueryBuilder, private, already
      # mixed into this class) UNCHANGED against the cache table's own
      # `value` column instead of a jsonb path expression — the exact
      # same operator compilation (`eq`/`ne`/`gt`/`gte`/`lt`/`lte`/`in`)
      # a live query already gets against the real column, so a cached
      # field supports every comparator `super` would have, not just the
      # `eq` example in the plan doc's own illustration.
      def cache_phase(cached)
        binds = []
        clauses = cached.map do |clause, value|
          cache_table = @lineage.field_cache(table, @era, clause.field.to_s)
          "SELECT id FROM #{quote_ident(cache_table)} WHERE #{where_clause(clause.op.to_s, quote_ident('value'), value, binds,
                                                                           field: clause.field)}"
        end
        @db.exec_params(clauses.join("\nINTERSECT\n"), binds).map { |row| row["id"] }
      end

      # PHASE TWO — `head_view`, restricted to phase one's candidate ids
      # PLUS whatever clauses phase one couldn't accelerate, applied
      # exactly the way `SqlQueryBuilder#query` (`super`) already applies
      # every clause today: against the fully-reduced view, which is
      # already correct regardless of caching (see this file's own
      # `query` comment — a cache is a SPEED shortcut, never a
      # correctness fix; head_view was always safe to filter directly,
      # just expensive to reduce in the first place). Duplicates a small
      # slice of `SqlQueryBuilder#query`'s own tail assembly (order_by/
      # limit/offset) rather than reaching into it — principle 2
      # (docs/implemented/postgres-era-adapter-split-plan.md): SqlQueryBuilder stays
      # untouched by the era workaround, so this stays local to
      # PostgresEra rather than growing a shared hook only one adapter
      # would ever call.
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

        sql = +"SELECT #{select_list} FROM #{from_relation} WHERE #{clauses.join(' AND ')}"
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

      def create_event_table!
        @db.exec(<<~SQL)
          CREATE TABLE IF NOT EXISTS events (
            id           bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
            name         text NOT NULL,
            aggregate    text NOT NULL,
            aggregate_id text NOT NULL,
            payload      jsonb,
            occurred_at  text
          )
        SQL
      end

      def create_saga_table!
        @db.exec(<<~SQL)
          CREATE TABLE IF NOT EXISTS hecks_saga_instances (
            domain          text NOT NULL,
            process_manager text NOT NULL,
            correlation     text NOT NULL,
            state           text NOT NULL,
            memory          jsonb NOT NULL,
            updated_at      timestamptz NOT NULL DEFAULT now(),
            PRIMARY KEY (domain, process_manager, correlation)
          )
        SQL
      end
    end
  end
end
