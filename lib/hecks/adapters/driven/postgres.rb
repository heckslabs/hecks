require "json"

require_relative "sql_query_builder"
require_relative "postgres/schema_builder"
require_relative "postgres/codec"
require_relative "../../ports/persistence/append_only"
require_relative "../../query_specification/common/null_policy"
require_relative "../../query_specification/common/order_by"
require_relative "../../query_specification/field_path"
require_relative "../../runtime/errors"
require_relative "../../runtime/event"
require_relative "../../runtime/instance"

module Hecks
  module Adapters
    # The plain Postgres store — flat, one table per aggregate, real
    # typed columns for scalars and jsonb for nested/list attributes,
    # exactly the shape `Sqlite` already made for its own table. Sibling
    # to `PostgresEra` (postgres_era.rb), which is the same database with
    # full lineage/era machinery on top — pick this one unless a domain
    # actually needs to survive a live shape change. See
    # docs/implemented/postgres-era-adapter-split-plan.md for why the two are split.
    #
    # No `hecks_eras`, no lineage, no advisory-lock-per-write for era
    # tracking, no `lineage_capable?`/`era_check!` — this class simply
    # doesn't define those methods at all, and the capability idiom
    # elsewhere already treats their absence as "not lineage-capable".
    #
    # Storage shape (see postgres/schema_builder.rb for the DDL,
    # postgres/codec.rb for the encode/decode):
    # - One real column per attribute, typed for a scalar
    #   (`SQL_TYPES`, `text` default), `jsonb` for a nested (value-object)
    #   or list-typed attribute — never JSON-in-TEXT the way `Sqlite` has
    #   to, since Postgres has a native jsonb type.
    # - `append` and `project` are two real Postgres statements — `save`/
    #   `delete` wrap them in ONE transaction, same "the journal insert
    #   and the snapshot stay atomic" reasoning `PostgresEra#append`'s own
    #   comment gives: a crash between the two must never leave a
    #   half-written state. `append`/`project` stay plain, individually-
    #   callable methods (never wrapping their own transaction) so
    #   `AppendOnly#recover!`'s replay — `project` alone, no `append` —
    #   keeps working the same way it does on every other adapter.
    class Postgres
      include SqlQueryBuilder
      include SchemaBuilder
      include Codec

      SQL_TYPES = { "Integer" => "bigint", "Float" => "double precision" }.freeze

      attr_reader :aggregate

      def persistence_capabilities = [:atomic_put, :optimistic_concurrency]

      def self.connect_for(name, settings)
        # LAZY, ON PURPOSE — same reasoning as PostgresEra's own
        # connect_for: a domain that never wires Postgres should never
        # need the gem installed.
        require "pg"

        declared = settings[:database] || settings["database"]
        if declared.to_s.empty?
          raise Runtime::WiringError,
                "#{name} binds Postgres, which needs a database connection, " \
                "but its world declares no \"database\"."
        end

        connection =
          if declared.start_with?("postgres://", "postgresql://")
            PG.connect(declared)
          else
            PG.connect(dbname: declared)
          end

        # SHARED-INSTANCE ISOLATION — same as PostgresEra's own: a
        # domain that declares `schema` is sharing its Postgres instance
        # with other domains, so every unqualified reference this
        # adapter constructs resolves through search_path. A domain with
        # no `schema` setting keeps Postgres's own default (public).
        schema = settings[:schema] || settings["schema"]
        connection.exec("SET search_path TO #{connection.quote_ident(schema)}") if schema.to_s != ""

        # QUIET ON PURPOSE — same reasoning as PostgresEra's own: a
        # schema/table that already exists is the ORDINARY case on every
        # boot after the first, not news.
        connection.exec("SET client_min_messages = warning")
        connection
      rescue PG::Error => error
        raise Runtime::WiringError,
              "cannot bind Postgres at #{declared} for #{name}: #{error.message.strip}"
      end

      def initialize(aggregate:, settings: {}, root: nil)
        @aggregate = aggregate
        @db = self.class.connect_for(aggregate.name, settings)
        # THE OPTIONAL saga-persistence capability's own scoping column
        # (§2/§4) — falls back to the aggregate's own storage name for a
        # directly-instantiated adapter (specs), same fallback shape
        # Sqlite's own @domain already uses.
        @domain = (settings[:domain] || settings["domain"] || aggregate.storage_name).to_s

        create_aggregate_table!
        create_entry_table!
        create_event_table!
        create_saga_table!
      end

      def table = @aggregate.storage_name

      def find(id)
        result = @db.exec_params("SELECT * FROM #{quoted_table} WHERE id = $1", [id.to_s])
        return nil if result.ntuples.zero?

        instance_from_row(result[0])
      end

      # order_by IS A RUNTIME VALUE — see Sqlite#all's own reasoning;
      # whitelisted the identical way before it ever reaches
      # order_expression.
      def all(order_by: nil, direction: :asc)
        order_sql = "ORDER BY id"
        if order_by
          name = order_by.to_s.split(".").first
          raise Runtime::WiringError, "#{@aggregate.name} has no attribute #{order_by.inspect} to order by" unless @aggregate.lifecycle&.field.to_s == name || @aggregate.attribute(name)

          spec = QuerySpecification::Common::OrderBy.new(field: order_by, direction: direction)
          order_sql = "ORDER BY #{order_clause(spec, nil)}"
        end

        @db.exec("SELECT * FROM #{quoted_table} #{order_sql}").map { |row| instance_from_row(row) }
      end

      def count = @db.exec("SELECT COUNT(*) FROM #{quoted_table}")[0]["count"].to_i

      def append(entry)
        @db.exec_params(
          "INSERT INTO #{quoted_entry_table} (aggregate_id, operation, state, mirrors) VALUES ($1, $2, $3, $4)",
          [entry.id, entry.operation, JSON.generate(entry.state), JSON.generate(entry.mirrors)]
        )
        entry
      end

      # `expected_version:` requests optimistic-concurrency CAS (see
      # `persistence_capabilities`/`Ports::Persistence::AppendOnly#save`).
      # `hecks_version` is ADAPTER BOOKKEEPING — never in `persisted_fields`
      # (Codec), so it never reaches `decode`'s domain-state hash. It goes
      # in the INSERT column list at `1` (a genuinely new row) and bumps by
      # one in the `ON CONFLICT DO UPDATE` branch; when `expected_version`
      # is given, that UPDATE branch additionally requires
      # `hecks_version = expected_version` to apply at all — Postgres's own
      # `INSERT ... ON CONFLICT DO UPDATE ... WHERE`, which gates only
      # whether the CONFLICT branch's update applies. A genuinely new row
      # never reaches that branch at all, so it always inserts regardless
      # of this WHERE. `RETURNING hecks_version` plus `ntuples.zero?` is
      # how a real version mismatch is told apart from an ordinary write:
      # zero rows back means the conflict branch's WHERE excluded the row
      # entirely — the version had already moved — so `nil` is returned
      # for the caller (`AppendOnly#save`) to treat as "stale, no-op".
      def project(entry, expected_version: nil)
        return @db.exec_params("DELETE FROM #{quoted_table} WHERE id = $1", [entry.id]) if entry.delete?

        instance = Runtime::Instance.new(aggregate: @aggregate, id: entry.id, state: entry.state)
        columns  = (["id"] + persisted_fields.map { |field| field[:name].to_s } + ["hecks_version"])
        values   = [instance.id.to_s] + persisted_fields.map { |field| encode_field(field, instance[field[:name]]) } + [1]
        updates  = persisted_fields.map { |field| "#{quote_ident(field[:name])} = EXCLUDED.#{quote_ident(field[:name])}" } +
                   ["hecks_version = #{quoted_table}.hecks_version + 1"]

        sql = "INSERT INTO #{quoted_table} (#{columns.map { |c| quote_ident(c) }.join(', ')}) " \
              "VALUES (#{(1..columns.size).map { |n| "$#{n}" }.join(', ')}) " \
              "ON CONFLICT (id) DO UPDATE SET #{updates.join(', ')}"
        if expected_version
          values += [expected_version]
          sql += " WHERE #{quoted_table}.hecks_version = $#{values.size}"
        end
        sql += " RETURNING hecks_version"

        result = @db.exec_params(sql, values)
        return nil if result.ntuples.zero?

        instance.version = result[0]["hecks_version"].to_i
        instance
      end

      def entries
        @db.exec("SELECT aggregate_id, operation, state, mirrors FROM #{quoted_entry_table} ORDER BY sequence").map do |row|
          state = JSON.parse(row["state"])
          Ports::Persistence::Entry.new(
            operation: row["operation"] || "save",
            id:        row["aggregate_id"],
            state:     state&.transform_keys(&:to_sym),
            mirrors:   row["mirrors"] && JSON.parse(row["mirrors"])
          )
        end
      end

      def reset!
        @db.exec("DELETE FROM #{quoted_table}")
        @db.exec("DELETE FROM #{quoted_entry_table}")
        self
      end

      # ONE TRANSACTION, not the plain append-then-project two-step a
      # file-based adapter needs a crash-recovery replay for (Heki) —
      # real Postgres ACID atomicity is sitting right there, so a crash
      # between the journal insert and the table upsert must not leave
      # the two disagreeing. `append`/`project` themselves stay plain,
      # transaction-free methods (see the class comment above) — the
      # transaction lives here, the one caller that runs both together.
      def save(instance)
        entry = Ports::Persistence::Entry.new(operation: "save", id: instance.id.to_s, state: instance.state.dup)
        @db.transaction { append(entry); project(entry) }
      end

      # Classification, journal append and snapshot replacement are one
      # Postgres transaction. A row lock cannot serialize two first writers —
      # there is no row to lock yet — so a transaction-scoped advisory lock on
      # schema/table + aggregate id owns that missing-row race as well. Once a
      # writer acquires it, the preceding writer has committed and status can
      # be read from the materialized table without a runtime-side find.
      def atomic_put(entry, insert_only: false)
        status = nil
        @db.transaction do
          @db.exec_params(
            "SELECT pg_advisory_xact_lock(" \
            "hashtext(current_schema() || ':' || $1), hashtext($2))",
            [table, entry.id.to_s]
          )
          exists = !@db.exec_params(
            "SELECT 1 FROM #{quoted_table} WHERE id = $1",
            [entry.id.to_s]
          ).ntuples.zero?
          if insert_only && exists
            status = :conflicted
            next
          end
          status = exists ? :replaced : :inserted
          append(entry)
          project(entry)
        end
        status
      end

      def delete(id)
        entry = Ports::Persistence::Entry.new(operation: "delete", id: id.to_s, state: nil)
        @db.transaction { append(entry); project(entry) }
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

      # ── the OPTIONAL saga-persistence capability (§2) — same DDL and
      # shape as PostgresEra's own (postgres_era.rb), not lineage-
      # specific, copied verbatim.
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

      def select_list = "*"
      def from_relation = quoted_table
      def dialect_name = "Postgres"
      def empty_in_clause = "FALSE"

      def placeholder(binds, value)
        binds << value
        "$#{binds.size}"
      end

      def contains_clause(expression, placeholder)
        "position(#{placeholder} in #{expression}) > 0"
      end

      # THE LIST COLUMN ITSELF IS THE JSONB ARRAY — no reaching into a
      # shared blob a jsonb path has to walk into first (PostgresEra's
      # own version does, since every attribute there shares one `state`
      # column). Here, `column` names a real column of its own, already
      # jsonb, already the array.
      def list_contains_clause(column, member, placeholder)
        target = member.empty? ? "elem #>> '{}'" : "elem ->> #{text_literal(member)}"
        elements = "jsonb_array_elements(#{quote_ident(column)}) AS elem"
        "EXISTS (SELECT 1 FROM #{elements} WHERE #{target} = #{placeholder})"
      end

      def plain_column(name) = quote_ident(name)

      # PostgresEra's own `jsonb_path` walks `[name, *path]` into ONE
      # shared `state` column — the attribute name is PART of the path
      # there. Here the attribute name IS THE COLUMN: the path into it
      # is whatever is LEFT after the column, never the column name
      # repeated inside its own path.
      def nested_expression(name, path, member)
        segments = path.empty? ? [(member || "value").to_s] : path
        jsonb_path(name, segments)
      end

      # Scalar, non-value-object attributes get a REAL typed column
      # (bigint/double precision/text) — comparing and sorting one needs
      # no cast at all, unlike PostgresEra's shared jsonb `state` blob,
      # where even a top-level scalar only ever comes out of `#>>` as
      # text. A jsonb-extracted value (a value-object member reached
      # through `nested_expression`/`jsonb_path` above) still comes out
      # of `#>>` as text the exact same way PostgresEra's own does, and
      # still needs the same `::numeric` cast to compare/sort
      # numerically rather than lexicographically. `jsonb_extraction?`
      # tells the two apart by inspecting the expression `query_expression`
      # already built — never a second, hand-rolled field walk that
      # could disagree with the one the SQL actually uses.
      def comparable_expression(expression, value)
        value.is_a?(Numeric) && jsonb_extraction?(expression) ? "(#{expression})::numeric" : expression
      end

      def execute_query(sql, binds)
        @db.exec_params(sql, binds).map { |row| instance_from_row(row) }
      end

      # Stamps `.version` (adapter bookkeeping, never domain state — see
      # `Instance`'s own comment) from the row's `hecks_version` column on
      # every Instance this adapter builds from a real stored row, so a
      # later `save`'s optimistic-concurrency CAS has something to check
      # against.
      def instance_from_row(row)
        instance = Runtime::Instance.new(aggregate: @aggregate, id: row["id"], state: decode(row))
        instance.version = row["hecks_version"].to_i
        instance
      end

      # ── the rest of the dialect ─────────────────────────────────────

      def quote_ident(name) = PG::Connection.quote_ident(name.to_s)
      def quoted_table = quote_ident(table)
      def entry_table = "#{table}_entries"
      def quoted_entry_table = quote_ident(entry_table)

      def jsonb_extraction?(expression) = expression.include?("#>>")

      def order_expression(field)
        expression = query_expression(field)
        jsonb_extraction?(expression) && numeric_field?(field) ? "(#{expression})::numeric" : expression
      end

      # Postgres defaults to NULLS LAST on ASC — same override
      # PostgresEra's own order_clause carries, so a declared query
      # answers identically no matter which adapter serves it (the
      # port's in-memory semantics, which Sqlite's own default happens
      # to match, put null rows FIRST ascending and LAST descending).
      def order_clause(order_by, policy)
        direction = order_by.direction.to_s.downcase == "desc" ? "DESC" : "ASC"
        nulls = case policy&.mode.to_s
                when "first" then " NULLS FIRST"
                when "last" then " NULLS LAST"
                else direction == "DESC" ? " NULLS LAST" : " NULLS FIRST"
                end
        "#{order_expression(order_by.field)} #{direction}#{nulls}, id #{direction}"
      end

      # Same walk PostgresEra's own numeric_field? uses — decides
      # numericness at ANY depth from the declared shape itself, not a
      # runtime value.
      def numeric_field?(field)
        name, *path = field.to_s.split(".")
        QuerySpecification::FieldPath.numeric?(@aggregate.attribute(name), path) do |type|
          @aggregate.value_object(type)
        end
      end

      # ARRAY[...] of individually-escaped literals — same escaping
      # PostgresEra's own jsonb_path carries and the same reason: a
      # hand-rolled '{a,b,c}' array literal has no escaping at all, and
      # a segment is a field or value-object member name this method has
      # no way to know is always schema-declared.
      def jsonb_path(column, segments)
        "#{quote_ident(column)} #>> ARRAY[#{segments.map { |segment| text_literal(segment) }.join(', ')}]::text[]"
      end

      def text_literal(text) = "'#{text.to_s.gsub("'", "''")}'"
    end
  end
end
