module Hecks
  module Adapters
    class Sqlite
      # Automatic indexing (plan principle 3: derived from existing
      # declared `where`/`order_by` IR, no new DSL keyword) — split out
      # of `SchemaBuilder` only to keep that module under its line
      # budget; `SchemaBuilder#create_aggregate_table!` still calls
      # `ensure_indexes!` the same way, this runs unconditionally on
      # every boot, `CREATE INDEX IF NOT EXISTS`, the same self-healing
      # idiom `postgres_era.rb`'s own `ensure_head_snapshot!`/
      # `ensure_first_head!` already use.
      module IndexBuilder
        private

        # Every field a declared query ever filters or sorts on, across
        # the aggregate's own queries and every entity's own queries —
        # `query_surfaces` in `dsl/aggregate_builder.rb` walks the
        # identical pair. An entity's query still runs against this
        # table: it compiles through `query_expression`, which is
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
        #     expression index over `query_expression(field)`'s own
        #     `json_extract(...)` text. Reusing the query compiler's own
        #     expression, not re-deriving the string a second way, is
        #     the whole point: a textual mismatch between the index and
        #     what a real query compiles to is invisible to SQLite's
        #     planner, and two independent copies of this logic can only
        #     drift apart over time;
        #   - a list-typed attribute — no index. SQLite's `contains`
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
        # (`dsl/aggregate_builder.rb`) already refuses it at parse time.
        # This runs at adapter boot, not parse time, so it skips rather
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

        # `idx_<table>_<sanitized field>` — table-prefixed because
        # SQLite index names are global to the database, not scoped per
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
