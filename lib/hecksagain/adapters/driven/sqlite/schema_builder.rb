module Hecksagain
  module Adapters
    class Sqlite
      # The DDL: one table per aggregate head, an append-only entry table
      # beside it, the shared events table, and the two ALTERs that let an
      # older database grow the columns newer code writes.
      module SchemaBuilder
        private

        def create_aggregate_table!
          columns = persisted_fields.map { |field| "#{quote_ident(field[:name])} #{field[:sql_type]}" }
          @db.execute(
            "CREATE TABLE IF NOT EXISTS #{quoted_table} (id TEXT PRIMARY KEY#{columns.empty? ? '' : ', '}#{columns.join(', ')})"
          )
          # RIGHT HERE, NOT AS A SEPARATE STEP IN `Sqlite#initialize` —
          # `create_aggregate_table!` is the one piece of DDL `D1`
          # already calls verbatim through this same shared module
          # (`d1.rb`'s own header: "reuses Sqlite::SchemaBuilder and
          # Sqlite::Codec UNCHANGED"). Folding index creation in here,
          # right after the table it indexes exists, is what makes D1's
          # own automatic indexing a real, running thing rather than an
          # aspiration that only Sqlite ever calls — no D1-specific
          # wiring needed, because D1 never has to know this exists.
          ensure_indexes!
        end

        def create_event_table!
          @db.execute(<<~SQL)
            CREATE TABLE IF NOT EXISTS events (
              id           INTEGER PRIMARY KEY AUTOINCREMENT,
              name         TEXT NOT NULL,
              aggregate    TEXT NOT NULL,
              aggregate_id TEXT NOT NULL,
              payload      TEXT,
              occurred_at  TEXT
            )
          SQL
        end

        def create_entry_table!
          @db.execute(<<~SQL)
            CREATE TABLE IF NOT EXISTS #{quoted_entry_table} (
              sequence     INTEGER PRIMARY KEY AUTOINCREMENT,
              aggregate_id TEXT NOT NULL,
              operation    TEXT NOT NULL DEFAULT 'save',
              state        TEXT NOT NULL,
              mirrors      TEXT
            )
          SQL
        end

        def ensure_entry_operation_column!
          columns = @db.execute("PRAGMA table_info(#{quoted_entry_table})").map { |row| row["name"] }
          return if columns.include?("operation")

          @db.execute("ALTER TABLE #{quoted_entry_table} ADD COLUMN operation TEXT NOT NULL DEFAULT 'save'")
        end

        def ensure_entry_mirrors_column!
          columns = @db.execute("PRAGMA table_info(#{quoted_entry_table})").map { |row| row["name"] }
          return if columns.include?("mirrors")

          @db.execute("ALTER TABLE #{quoted_entry_table} ADD COLUMN mirrors TEXT")
        end

        # THE OPTIONAL saga-persistence capability's own table (§2/§4) —
        # shared here so `D1`, which `include`s this module verbatim for
        # its own `events`-table DDL (`d1.rb`), gets this for free too.
        # `domain` stays an explicit column even though SQLite has no
        # schema/namespace concept the way Postgres does — matches
        # `hecks_saga_instances`' own Postgres shape (§3) and covers the
        # (uncommon but real) case of a domain explicitly sharing one
        # `database` file/D1 database with another.
        def create_saga_table!
          @db.execute(<<~SQL)
            CREATE TABLE IF NOT EXISTS hecks_saga_instances (
              domain          TEXT NOT NULL,
              process_manager TEXT NOT NULL,
              correlation     TEXT NOT NULL,
              state           TEXT NOT NULL,
              memory          TEXT NOT NULL,
              PRIMARY KEY (domain, process_manager, correlation)
            )
          SQL
        end

        def sql_type(attr)
          return "TEXT" if attr.list?

          SQL_TYPES.fetch(attr.type, "TEXT")
        end

        # ── automatic indexing (plan principle 3: derived from existing
        # declared `where`/`order_by` IR, no new DSL keyword — this runs
        # unconditionally on every boot, `CREATE INDEX IF NOT EXISTS`,
        # the same self-healing idiom `postgres_era.rb`'s own
        # `ensure_head_snapshot!`/`ensure_first_head!` already use) ────

        # Every field a declared query ever filters or sorts on, across
        # the aggregate's OWN queries and every entity's own queries —
        # `query_surfaces` in `dsl/aggregate_builder.rb` walks the
        # identical pair. AN ENTITY'S QUERY STILL RUNS AGAINST THIS
        # TABLE: it compiles through `query_expression`, which is
        # `@aggregate`-scoped, not entity-scoped, so an entity's
        # declared `where`/`order_by` is indexed here too, same as any
        # other declared query — not skipped as "some other table's
        # concern."
        def ensure_indexes!
          declared_query_fields.each { |field| ensure_index_for_field!(field) }
        end

        def declared_query_fields
          queries = @aggregate.queries + @aggregate.entities.flat_map(&:queries)
          queries.flat_map { |query| query.wheres.map(&:field) + [query.order_by&.field] }
                 .compact.map(&:to_s).uniq
        end

        # One field name resolves to exactly one of three outcomes:
        #
        #   - a plain scalar attribute (or the lifecycle field itself)
        #     — a real btree index on the column, using `plain_column`'s
        #     own `quote_ident(name)` phrasing (reached by calling
        #     `query_expression` itself, not a second copy of its
        #     plain-vs-nested decision);
        #   - a non-list value-object attribute, referenced bare or
        #     through a member path (`field` or `field.member`) — an
        #     EXPRESSION index over `query_expression(field)`'s own
        #     `json_extract(...)` text. Reusing the query compiler's own
        #     expression, not re-deriving the string a second way, is
        #     the whole point: a textual mismatch between the index and
        #     what a real query compiles to is invisible to SQLite's
        #     planner, and two independent copies of this logic can only
        #     drift apart over time;
        #   - a list-typed attribute — NO index. SQLite's `contains`
        #     compiles to `EXISTS (SELECT 1 FROM json_each(col) WHERE
        #     ...)` (`list_contains_clause`, in `sql_query_builder.rb`)
        #     — an element-membership scan a plain index on the raw
        #     column (or even an expression index on it) does nothing to
        #     speed, since neither indexes the elements individually.
        #     SQLite has no inverted/array index short of FTS5/R-tree,
        #     and neither fits a `list_of` scalar or value-object field
        #     — well beyond this plan's scope. Left unindexed
        #     deliberately, not a silent gap.
        #
        # A field naming neither a real attribute nor the lifecycle
        # field can't happen through the DSL today — `seal_query_field`
        # (`dsl/aggregate_builder.rb`) already refuses it at PARSE time.
        # This runs at adapter BOOT, not parse time, so it skips rather
        # than crashes ugly if that invariant is ever violated.
        def ensure_index_for_field!(field)
          name, * = field.to_s.split(".")
          attribute = @aggregate.attribute(name)
          lifecycle_field = @aggregate.lifecycle&.field.to_s == name

          return if !lifecycle_field && attribute.nil?
          return if attribute&.list?

          expression = query_expression(field)
          @db.execute(
            "CREATE INDEX IF NOT EXISTS #{quote_ident(index_name(field))} ON #{quoted_table}(#{expression})"
          )
        end

        # `idx_<table>_<sanitized field>` — TABLE-PREFIXED because
        # SQLite index names are GLOBAL to the database, not scoped per
        # table the way a column name is; two different aggregates each
        # indexing a field called "name" would collide without it. The
        # field itself is sanitized (a dotted path's "." in particular)
        # to stay a valid identifier while remaining visibly tied to
        # what it indexes — collision-free across every field/path this
        # aggregate declares, since `declared_query_fields` already
        # de-duplicates the field strings themselves.
        def index_name(field)
          sanitized = field.to_s.gsub(/[^a-zA-Z0-9_]/, "_")
          "idx_#{table}_#{sanitized}"
        end
      end
    end
  end
end
