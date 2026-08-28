require "digest"

module Hecks
  module Adapters
    class Postgres
      # The DDL: one table per aggregate, a real column per attribute (a
      # jsonb column per nested/list attribute), an append-only entry
      # table beside it, the shared events/saga tables — and the automatic
      # indexing this adapter carries that `PostgresEra` does not (see
      # docs/implemented/postgres-era-adapter-split-plan.md, governing principle 3:
      # every field a declared query filters or sorts on is safe to index
      # directly here, since there is no `head_view` reduction to route
      # around the way `PostgresEra`'s own cache-table story exists for).
      module SchemaBuilder
        private

        def create_aggregate_table!
          columns = persisted_fields.map { |field| "#{quote_ident(field[:name])} #{field[:sql_type]}" }
          @db.exec(
            "CREATE TABLE IF NOT EXISTS #{quoted_table} (id text PRIMARY KEY#{columns.empty? ? '' : ', '}#{columns.join(', ')})"
          )
          # SELF-HEALING, SAME IDIOM AS `ensure_indexes!` BELOW —
          # `CREATE TABLE IF NOT EXISTS` above does NOT retroactively add a
          # column to an already-existing table (a committed database from
          # before optimistic-concurrency CAS existed), so this runs
          # unconditionally on every boot and no-ops once the column is
          # there. ADAPTER BOOKKEEPING ONLY — never listed in
          # `persisted_fields` (Codec), so it never appears in `decode`'s
          # domain-state hash or `Instance#to_h`.
          @db.exec("ALTER TABLE #{quoted_table} ADD COLUMN IF NOT EXISTS hecks_version bigint NOT NULL DEFAULT 1")
          # RIGHT HERE, NOT A SEPARATE STEP IN `Postgres#initialize` —
          # same idiom Sqlite::SchemaBuilder's own `create_aggregate_table!`
          # uses: index creation runs unconditionally, right after the
          # table it indexes exists, the same self-healing shape
          # `ensure_head_snapshot!`/`ensure_first_head!` already use on
          # `PostgresEra`'s side.
          ensure_indexes!
        end

        def create_entry_table!
          @db.exec(<<~SQL)
            CREATE TABLE IF NOT EXISTS #{quoted_entry_table} (
              sequence     bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
              aggregate_id text NOT NULL,
              operation    text NOT NULL DEFAULT 'save',
              state        jsonb NOT NULL,
              mirrors      jsonb
            )
          SQL
        end

        # Same DDL as `PostgresEra`'s own — not lineage-specific, copied
        # verbatim (see docs/implemented/postgres-era-adapter-split-plan.md).
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

        # Same DDL as `PostgresEra`'s own — not lineage-specific, copied
        # verbatim (see docs/implemented/postgres-era-adapter-split-plan.md).
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
          # `CREATE TABLE IF NOT EXISTS` above is a no-op against a table
          # this same domain already created before this column existed
          # — the same idiom `rust/host/src/journal.rs`'s own
          # `sagas_backfilled` column addition already uses, for the
          # identical reason.
          @db.exec("ALTER TABLE hecks_saga_instances ADD COLUMN IF NOT EXISTS completed_compensations jsonb NOT NULL DEFAULT '[]'::jsonb")
        end

        def sql_type(attr)
          return "jsonb" if attr.list? || value_object?(attr)

          SQL_TYPES.fetch(attr.type, "text")
        end

        # ── automatic indexing ───────────────────────────────────────
        #
        # Derived from every declared query's `where`/`order_by` fields —
        # no bluebook author opts in, matching every other self-healing
        # schema move this adapter makes. Walks the aggregate's own
        # queries AND each entity's own queries — the same enumeration
        # `dsl/aggregate_builder.rb`'s own `query_surfaces` walks at
        # declaration-seal time — but an entity's own fields never
        # produce an index below: an entity has no table of its own, its
        # rows live inside a LIST-typed attribute on the AGGREGATE's own
        # table (`QueryInterpreter#entity_rows` resolves it that way, and
        # answers an entity query entirely in memory over `repository.all`
        # — it never reaches this adapter's own `query` method at all).
        # Every list-typed attribute is excluded below regardless (see
        # `index_field!`), so an entity's own field would always resolve
        # to "skip" anyway. Walked explicitly rather than silently
        # dropped, so a reader can see entities were considered here, not
        # forgotten.
        def ensure_indexes!
          query_surfaces.each do |owner, queries|
            next unless owner.equal?(@aggregate)

            queries.each { |query| index_query!(query) }
          end
        end

        def query_surfaces
          [[@aggregate, @aggregate.queries]] +
            @aggregate.entities.map { |entity| [entity, entity.queries] }
        end

        def index_query!(query)
          query.wheres.each { |clause| index_field!(clause.field) }
          index_field!(query.order_by.field) if query.order_by
        end

        # A `list_of` attribute is never indexed here — this adapter's
        # own `contains` on a list field compiles to `EXISTS (SELECT 1
        # FROM jsonb_array_elements(...) ...)` (see `list_contains_clause`
        # below), a SQL shape neither a plain btree on the raw jsonb
        # column nor even a GIN jsonb index (`@>`, `?`) accelerates —
        # Postgres's own GIN jsonb operators match a DIFFERENT SQL shape
        # than the `EXISTS` + `jsonb_array_elements` this codebase always
        # compiles a list `contains` to. An index here would be dead
        # weight, not free correctness, so none is attempted.
        def index_field!(field)
          # A HOP PATH ("owner/field" — `Bluebook::AggregateBuilder`'s own
          # convention for a field reached by crossing a reference,
          # `aggregate_builder.rb`'s own `field.to_s.include?("/")`
          # checks) IS NEVER INDEXED HERE — same reasoning as `list_of`
          # below: `query_expression`/`nested_expression` below have no
          # dialect for this shape at all (they'd compile the whole
          # "owner/field" string as one bare column/jsonb-path segment,
          # which is not a real column and errors PG::UndefinedColumn on
          # `CREATE INDEX`, discovered fuzzing a real Postgres boot of
          # `examples/banking` — Account's own `projects :customer_status,
          # from: :"customer.status"` compiles to exactly this shape).
          # Skipping the index is always safe, the same way skipping a
          # `list_of` index is: an index is a perf optimization, not
          # correctness, so "never built" beats "built wrong." Whether a
          # hop-path field can be QUERIED at all against this adapter is
          # a separate, still-open question this skip does not answer —
          # see docs/future-features.md's fuzzer-adapter entry, and
          # docs/1.0-readiness.md item 2 for this gap's OTHER two
          # independent failure points (Postgres querying, Rust codegen's
          # `OpenForSuspendedCustomers` — bin/rust_coverage's own
          # allowlist) — tracked together, not as three unrelated bugs.
          return if field.to_s.include?("/")

          name, *_path = field.to_s.split(".")
          attribute = @aggregate.attribute(name)
          return if attribute&.list?

          # THE SAME EXPRESSION THE QUERY ITSELF COMPILES TO — calling
          # `query_expression`/`plain_column`, the real dialect methods,
          # rather than a second, hand-rolled derivation of the same
          # path that could silently drift from it. An index whose
          # expression doesn't match the planner's own candidate
          # expression byte-for-byte is invisible to the planner,
          # created or not.
          expression = query_expression(field.to_s)
          if expression == plain_column(name)
            create_plain_index!(name)
          else
            create_expression_index!(expression, field.to_s)
          end
        end

        def create_plain_index!(column)
          name = index_name(column.to_s)
          @db.exec("CREATE INDEX IF NOT EXISTS #{quote_ident(name)} ON #{quoted_table} (#{quote_ident(column)})")
        end

        def create_expression_index!(expression, field)
          name = index_name(field)
          @db.exec("CREATE INDEX IF NOT EXISTS #{quote_ident(name)} ON #{quoted_table} ((#{expression}))")
        end

        # Postgres identifiers cap at 63 bytes. Hashing TABLE + FIELD
        # together keeps every generated index name well under that no
        # matter how long an aggregate or attribute name gets, and keeps
        # two distinct fields — on the same table or different ones —
        # from ever colliding, or truncating into the same name the way
        # a naive `"idx_#{table}_#{field}"` could once either got long
        # enough.
        def index_name(field)
          "hecks_idx_#{Digest::SHA256.hexdigest("#{table}:#{field}")[0, 40]}"
        end
      end
    end
  end
end
