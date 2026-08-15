require "json"

require_relative "sql_query_builder"
require_relative "postgres_era/lineage"
require_relative "postgres_era/lineage_manager"
require_relative "../../ports/persistence/append_only"
require_relative "../../query_specification/common/order_by"
require_relative "../../runtime/errors"
require_relative "../../runtime/event"
require_relative "../../runtime/instance"
require_relative "../../runtime/registry"

module Hecksagain
  module Adapters
    # The enforcement-grade persistence adapter — and the only one that
    # declares the LINEAGE capability: it may act on shape drift
    # (translate, fork, merge) where every other adapter can only refuse
    # toward it. Sibling to the plain `Postgres` adapter (postgres.rb),
    # which is the same database with none of this machinery — pick
    # PostgresEra only once a domain actually needs to survive a shape
    # change live. See docs/postgres-era-adapter-split-plan.md for why
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

      # The capability idiom: only PostgresEra answers true, and only
      # PostgresEra carries an era_check! for the boot gate to delegate to.
      def self.lineage_capable? = true

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
        connection.exec("SET search_path TO #{connection.quote_ident(schema)}") if schema.to_s != ""

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
        unless @aggregate.lifecycle&.field.to_s == name || @aggregate.attribute(name)
          raise Runtime::WiringError, "#{@aggregate.name} has no attribute #{order_by.inspect} to order by"
        end

        spec = QuerySpecification::Common::OrderBy.new(field: order_by, direction: direction)
        @db.exec(%(SELECT id, state FROM #{quoted_head} ORDER BY #{order_clause(spec, nil)})).map { |row| instance(row) }
      end

      def count = @db.exec(%(SELECT COUNT(*) FROM #{quoted_head}))[0]["count"].to_i

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
          @db.exec_params(
            "SELECT pg_advisory_xact_lock(hashtext('hecks_ordinal:' || $1))",
            [@lineage.domain]
          )
          ordinal = @db.exec_params(
            "INSERT INTO #{@lineage.quoted_journal} (era, aggregate, aggregate_id, operation, state, mirrors) " \
            "VALUES ($1, $2, $3, $4, $5, $6) RETURNING ordinal",
            [@era, table, entry.id, entry.operation,
             entry.state && JSON.generate(entry.state), entry.mirrors && JSON.generate(entry.mirrors)]
          )[0]["ordinal"]

          if entry.save?
            @db.exec_params(
              "INSERT INTO #{quoted_head_snapshot} (id, ordinal, state) VALUES ($1, $2, $3) " \
              "ON CONFLICT (id) DO UPDATE SET ordinal = EXCLUDED.ordinal, state = EXCLUDED.state " \
              "WHERE #{quoted_head_snapshot}.ordinal < EXCLUDED.ordinal",
              [entry.id, ordinal, JSON.generate(entry.state)]
            )
          else
            @db.exec_params("DELETE FROM #{quoted_head_snapshot} WHERE id = $1", [entry.id])
          end
        end
        entry
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
