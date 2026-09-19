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
require_relative "postgres/outbox"
require_relative "postgres/reconnect"
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
    # ## What it is not
    #
    # No `hecks_eras`, no lineage, no advisory-lock-per-write for era
    # tracking, no `lineage_capable?`/`era_check!` — this class simply
    # doesn't define those methods at all, and the capability idiom
    # elsewhere already treats their absence as "not lineage-capable".
    #
    # ## Storage shape
    #
    # See postgres/schema_builder.rb for the DDL, postgres/codec.rb for the
    # encode/decode.
    #
    # - One real column per attribute, typed for a scalar
    #   (`SQL_TYPES`, `text` default), `jsonb` for a nested (value-object)
    #   or list-typed attribute — never JSON-in-text the way `Sqlite` has
    #   to, since Postgres has a native jsonb type.
    # - `append` and `project` are two real Postgres statements — `save`/
    #   `delete` wrap them in one transaction, same "the journal insert
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
      include PostgresOutbox
      include PostgresReconnect

      SQL_TYPES = { "Integer" => "bigint", "Float" => "double precision" }.freeze

      attr_reader :aggregate

      # Names the optional persistence capabilities `Ports::Persistence::AppendOnly` may rely on.
      #
      # @return [Array<Symbol>] `[:atomic_put, :optimistic_concurrency]`
      def persistence_capabilities = [:atomic_put, :optimistic_concurrency]

      # Opens a connection to the database a world declares, scoped to its `schema` if any.
      #
      # @param name [String] the aggregate's name, used only in error messages
      # @param settings [Hash{Symbol, String => Object}] world settings for the binding;
      #   `database` (a database name or a `postgres://` URL) is required and `schema` is
      #   optional, each read under a Symbol or a String key
      # @return [PG::Connection] a live connection with `search_path` and
      #   `client_min_messages` already set
      # @raise [Runtime::WiringError] if the settings declare no `database`, or Postgres
      #   refuses the connection or the `SET` statements
      # @raise [LoadError] if the `pg` gem is not installed
      def self.connect_for(name, settings)
        # **Lazy, on purpose** — same reasoning as PostgresEra's own
        # connect_for: a domain that never wires Postgres should never
        # need the gem installed.
        require "pg"

        declared = settings.key?(:database) ? settings[:database] : settings["database"]
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

        # **Shared-instance isolation** — same as PostgresEra's own: a
        # domain that declares `schema` is sharing its Postgres instance
        # with other domains, so every unqualified reference this
        # adapter constructs resolves through search_path. A domain with
        # no `schema` setting keeps Postgres's own default (public).
        schema = settings.key?(:schema) ? settings[:schema] : settings["schema"]
        connection.exec("SET search_path TO #{connection.quote_ident(schema)}") if schema.to_s != ""

        # **Quiet on purpose** — same reasoning as PostgresEra's own: a
        # schema/table that already exists is the ordinary case on every
        # boot after the first, not news.
        connection.exec("SET client_min_messages = warning")
        connection
      rescue PG::Error => e
        raise Runtime::WiringError,
              "cannot bind Postgres at #{declared} for #{name}: #{e.message.strip}"
      end

      # Connects and creates the aggregate, journal, event, saga and outbox tables if absent.
      #
      # @param aggregate [Bluebook::Aggregate] the aggregate whose table this adapter owns
      # @param settings [Hash{Symbol, String => Object}] world settings for the binding:
      #   `database` (required), `schema` and `domain` (optional; `domain` defaults to the
      #   aggregate's storage name and scopes saga rows)
      # @param root [String, nil] project root directory; accepted for the shared adapter
      #   constructor shape and ignored
      # @raise [Runtime::WiringError] if the settings declare no `database` or the connection
      #   is refused
      # @raise [PG::Error] if creating a table or index fails
      def initialize(aggregate:, settings: {}, root: nil)
        @aggregate = aggregate
        @settings  = settings
        @db = self.class.connect_for(aggregate.name, settings)
        # The optional saga-persistence capability's own scoping column
        # (§2/§4) — falls back to the aggregate's own storage name for a
        # directly-instantiated adapter (specs), same fallback shape
        # Sqlite's own @domain already uses.
        @domain = (
          if settings.key?(:domain)
            settings[:domain]
          elsif settings.key?("domain")
            settings["domain"]
          else
            aggregate.storage_name
          end
        ).to_s

        create_aggregate_table!
        create_entry_table!
        create_event_table!
        create_saga_table!
        create_outbox_table!
      end

      # Names the aggregate's table; the journal table and outbox rows are keyed off it.
      #
      # @return [String] the aggregate's snake_case storage name, unquoted
      def table = @aggregate.storage_name

      # Reads the current row for one aggregate identity, stamped with its stored version.
      #
      # @param id [String, Object] the aggregate identity, bound as `id.to_s`
      # @return [Runtime::Instance, nil] the decoded record with `version` set, or nil when
      #   no row has that id
      # @raise [PG::Error] if the statement fails; a `PG::ConnectionBad` also triggers a
      #   reconnect for the next caller
      def find(id)
        result = pg_exec_params("SELECT * FROM #{quoted_table} WHERE id = $1", [id.to_s])
        return nil if result.ntuples.zero?

        instance_from_row(result[0])
      end

      # Lists every stored record, ordered by id unless an ordering attribute is given.
      #
      # order_by is a runtime value — see Sqlite#all's own reasoning;
      # whitelisted the identical way before it ever reaches
      # order_expression.
      #
      # @param order_by [String, Symbol, nil] attribute (or dotted value-object path) to sort
      #   by, with id as the tie-break; nil orders by id alone
      # @param direction [Symbol, String] `:asc` or `:desc`, case-insensitive; anything else
      #   sorts ascending
      # @return [Array<Runtime::Instance>] the decoded records with `version` set, `[]` when
      #   the table is empty
      # @raise [Runtime::WiringError] if `order_by` names no attribute of the aggregate
      # @raise [PG::Error] if the statement fails
      def all(order_by: nil, direction: :asc)
        order_sql = "ORDER BY id"
        if order_by
          name = order_by.to_s.split(".").first
          unless @aggregate.lifecycle&.field.to_s == name || @aggregate.attribute(name)
            raise Runtime::WiringError,
                  "#{@aggregate.name} has no attribute #{order_by.inspect} to order by"
          end

          spec = QuerySpecification::Common::OrderBy.new(field: order_by, direction: direction)
          order_sql = "ORDER BY #{order_clause(spec, nil)}"
        end

        pg_exec("SELECT * FROM #{quoted_table} #{order_sql}").map { |row| instance_from_row(row) }
      end

      # Counts the rows in the aggregate's table, deleted records excluded.
      #
      # @return [Integer] number of current records
      # @raise [PG::Error] if the statement fails
      def count = pg_exec("SELECT COUNT(*) FROM #{quoted_table}")[0]["count"].to_i

      # Inserts one journal row, outside any transaction of its own.
      #
      # @param entry [Ports::Persistence::Entry] the save or delete to journal; `state` is
      #   encoded through the state codec and `mirrors` stored as JSON, or NULL when nil
      # @return [Ports::Persistence::Entry] the same `entry`
      # @raise [PG::Error] if the insert fails
      def append(entry)
        pg_exec_params(
          "INSERT INTO #{quoted_entry_table} (aggregate_id, operation, state, mirrors) VALUES ($1, $2, $3, $4)",
          # `mirrors` (unlike `state`) is a nullable column — an absent
          # mirrors hash must bind a real SQL NULL, not the four-character
          # JSON text `"null"` (`JSON.generate(nil)`), or a future `IS NULL`
          # check against it would never match. Same guard `sqlite.rb`/
          # `d1.rb`/`postgres_era.rb` already use for their own journal's
          # `mirrors` column.
          [entry.id, entry.operation, state_json(entry.state), entry.mirrors && JSON.generate(entry.mirrors)]
        )
        entry
      end

      # Upserts or deletes the aggregate's row for one journal entry, bumping its version.
      #
      # `expected_version:` requests optimistic-concurrency CAS (see
      # `persistence_capabilities`/`Ports::Persistence::AppendOnly#save`).
      # `hecks_version` is adapter bookkeeping — never in `persisted_fields`
      # (Codec), so it never reaches `decode`'s domain-state hash. It goes
      # in the INSERT column list at `1` (a genuinely new row) and bumps by
      # one in the `ON CONFLICT DO UPDATE` branch; when `expected_version`
      # is given, that update branch additionally requires
      # `hecks_version = expected_version` to apply at all — Postgres's own
      # `INSERT ... ON CONFLICT DO UPDATE ... WHERE`, which gates only
      # whether the conflict branch's update applies. A genuinely new row
      # never reaches that branch at all, so it always inserts regardless
      # of this where. `RETURNING hecks_version` plus `ntuples.zero?` is
      # how a real version mismatch is told apart from an ordinary write:
      # zero rows back means the conflict branch's where excluded the row
      # entirely — the version had already moved — so `nil` is returned
      # for the caller (`AppendOnly#save`) to treat as "stale, no-op".
      #
      # @param entry [Ports::Persistence::Entry] the save or delete to materialize
      # @param expected_version [Integer, nil] the `hecks_version` the row must still hold for
      #   an update to apply; nil writes unconditionally. Ignored for a delete
      # @return [Runtime::Instance, PG::Result, nil] for a save, a new instance over the
      #   entry's state with `version` set to the stored `hecks_version`, or nil when
      #   `expected_version` no longer matched and nothing was written; for a delete, the
      #   `DELETE` statement's `PG::Result`
      # @raise [PG::Error] if the statement fails
      # rubocop:disable Metrics/AbcSize -- the CAS/plain upsert split is one
      # protocol; splitting it would hide the version handshake.
      def project(entry, expected_version: nil)
        return pg_exec_params("DELETE FROM #{quoted_table} WHERE id = $1", [entry.id]) if entry.delete?

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

        result = pg_exec_params(sql, values)
        return nil if result.ntuples.zero?

        instance.version = result[0]["hecks_version"].to_i
        instance
      end
      # rubocop:enable Metrics/AbcSize

      # Reads the whole journal back in append order, for `AppendOnly#recover!` to replay.
      #
      # @return [Array<Ports::Persistence::Entry>] every journalled entry, state decoded
      #   through the state codec and `mirrors` parsed with String keys (nil when none were
      #   stored); `[]` when nothing has been appended
      # @raise [PG::Error] if the statement fails
      # @raise [JSON::ParserError] if a stored `state` or `mirrors` value is not valid JSON
      def entries
        pg_exec("SELECT aggregate_id, operation, state, mirrors FROM #{quoted_entry_table} ORDER BY sequence").map do |row|
          state = JSON.parse(row["state"])
          Ports::Persistence::Entry.new(
            operation: row["operation"] || "save",
            id:        row["aggregate_id"],
            state:     Ports::Persistence::StateCodec.decode(@aggregate, state),
            mirrors:   row["mirrors"] && JSON.parse(row["mirrors"])
          )
        end
      end

      # Deletes every row of the aggregate's table and its journal; events, saga rows and
      # outbox rows are left in place.
      #
      # @return [Adapters::Postgres] self
      # @raise [PG::Error] if a statement fails
      def reset!
        pg_exec("DELETE FROM #{quoted_table}")
        pg_exec("DELETE FROM #{quoted_entry_table}")
        self
      end

      # Journals and upserts an instance's current state atomically.
      #
      # One transaction, not the plain append-then-project two-step a
      # file-based adapter needs a crash-recovery replay for (Heki) —
      # real Postgres ACID atomicity is sitting right there, so a crash
      # between the journal insert and the table upsert must not leave
      # the two disagreeing. `append`/`project` themselves stay plain,
      # transaction-free methods (see the class comment above) — the
      # transaction lives here, the one caller that runs both together.
      #
      # @param instance [Runtime::Instance] the instance to store
      # @return [Runtime::Instance] a new instance over the saved state, `version` set to the
      #   row's new `hecks_version`
      # @raise [PG::Error] if either statement fails; the transaction is rolled back
      def save(instance)
        entry = Ports::Persistence::Entry.new(operation: "save", id: instance.id.to_s, state: instance.state.dup)
        transaction do
          append(entry)
          project(entry)
        end
      end

      # Stores an entry under a per-identity advisory lock and reports whether it inserted,
      # replaced or conflicted, so two concurrent creators of one id cannot both insert.
      #
      # @param entry [Ports::Persistence::Entry] the save to store
      # @param insert_only [Boolean] when true, an existing row is left untouched
      # @return [Symbol] `:inserted`, `:replaced`, or `:conflicted` when `insert_only` met an
      #   existing row and nothing was written
      # @raise [PG::Error] if a statement fails; the transaction is rolled back
      def atomic_put(entry, insert_only: false)
        status = nil
        transaction do
          pg_exec_params(
            "SELECT pg_advisory_xact_lock(" \
            "hashtext(current_schema() || ':' || $1), hashtext($2))",
            [table, entry.id.to_s]
          )
          exists = !pg_exec_params(
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

      # Journals a delete and removes the row atomically, whether or not a row exists.
      #
      # @param id [String, Object] the aggregate identity, journalled as `id.to_s`
      # @return [Boolean] always true
      # @raise [PG::Error] if either statement fails; the transaction is rolled back
      def delete(id)
        entry = Ports::Persistence::Entry.new(operation: "delete", id: id.to_s, state: nil)
        transaction do
          append(entry)
          project(entry)
        end
        true
      end

      # Inserts an emitted event into the shared `events` table.
      #
      # @param event [Runtime::Event] the emitted event; `payload` is stored as JSON
      # @return [PG::Result] the insert's result; callers ignore it
      # @raise [PG::Error] if the insert fails
      def record_event(event)
        pg_exec_params(
          "INSERT INTO events (name, aggregate, aggregate_id, payload, occurred_at) VALUES ($1, $2, $3, $4, $5)",
          [event.name, event.aggregate, event.id.to_s, JSON.generate(event.payload), event.occurred_at]
        )
      end

      # Reads back every recorded event in insertion order — the whole `events` table, not
      # only this aggregate's rows.
      #
      # @return [Array<Runtime::Event>] the stored events, `payload` parsed with Symbol keys
      #   and `occurred_at` as the String Postgres returns; `[]` when none are recorded
      # @raise [PG::Error] if the statement fails
      def events
        pg_exec("SELECT * FROM events ORDER BY id").map do |row|
          Runtime::Event.new(
            name:        row["name"],
            aggregate:   row["aggregate"],
            id:          row["aggregate_id"],
            payload:     JSON.parse(row["payload"], symbolize_names: true),
            occurred_at: row["occurred_at"]
          )
        end
      end

      # Upserts one saga instance's checkpoint, keyed by domain, process manager and
      # correlation.
      #
      # ── the optional saga-persistence capability (§2) — same DDL and
      # shape as PostgresEra's own (postgres_era.rb), not lineage-
      # specific, copied verbatim.
      #
      # @param process_manager [String, Symbol] the process manager's name
      # @param correlation [String, Object] the instance's correlation value, stored as
      #   `correlation.to_s`
      # @param state [String, Symbol] the saga's current state name
      # @param memory [Hash] the saga's memory; must be JSON-serializable
      # @param completed_compensations [Array] the ledger of completed compensable legs; must
      #   be JSON-serializable
      # @return [PG::Result] the upsert's result; callers ignore it
      # @raise [PG::Error] if the statement fails
      def save_saga(process_manager:, correlation:, state:, memory:, completed_compensations: [])
        pg_exec_params(
          "INSERT INTO hecks_saga_instances (domain, process_manager, correlation, state, memory, completed_compensations) " \
          "VALUES ($1, $2, $3, $4, $5, $6) " \
          "ON CONFLICT (domain, process_manager, correlation) DO UPDATE " \
          "SET state = EXCLUDED.state, memory = EXCLUDED.memory, " \
          "completed_compensations = EXCLUDED.completed_compensations, updated_at = now()",
          [@domain, process_manager.to_s, correlation.to_s, state.to_s, JSON.generate(memory),
           JSON.generate(completed_compensations)]
        )
      end

      # Removes a finished saga instance's checkpoint; a missing row is not an error.
      #
      # @param process_manager [String, Symbol] the process manager's name
      # @param correlation [String, Object] the instance's correlation value, matched as
      #   `correlation.to_s`
      # @return [PG::Result] the delete's result; callers ignore it
      # @raise [PG::Error] if the statement fails
      def delete_saga(process_manager:, correlation:)
        pg_exec_params(
          "DELETE FROM hecks_saga_instances WHERE domain = $1 AND process_manager = $2 AND correlation = $3",
          [@domain, process_manager.to_s, correlation.to_s]
        )
      end

      # Yields every checkpointed saga instance of this adapter's domain, for
      # `Registry#rehydrate_sagas!` to restore at boot.
      #
      # @yieldparam process_manager [String] the process manager's name
      # @yieldparam correlation [String] the instance's correlation value
      # @yieldparam state [String] the saga's state name
      # @yieldparam memory [Hash{Symbol => Object}] the saga's memory, Symbol keys at every depth
      # @yieldparam completed_compensations [Array] the completed-compensation ledger, `[]`
      #   when the column is NULL
      # @return [Enumerator, PG::Result] an enumerator over the same five values when no block
      #   is given; otherwise the query result
      # @raise [PG::Error] if the statement fails
      def each_saga
        return enum_for(:each_saga) unless block_given?

        pg_exec_params(
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

      # The list column itself is the JSONB array — no reaching into a
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

      # PostgresEra's own `jsonb_path` walks `[name, *path]` into one
      # shared `state` column — the attribute name is part of the path
      # there. Here the attribute name is the column: the path into it
      # is whatever is left after the column, never the column name
      # repeated inside its own path.
      def nested_expression(name, path, member)
        segments = path.empty? ? [(member || "value").to_s] : path
        jsonb_path(name, segments)
      end

      # Scalar, non-value-object attributes get a real typed column
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
        pg_exec_params(sql, binds).map { |row| instance_from_row(row) }
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
      # numericness at any depth from the declared shape itself, not a
      # runtime value.
      def numeric_field?(field)
        name, *path = field.to_s.split(".")
        QuerySpecification::FieldPath.numeric?(@aggregate.attribute(name), path) do |type|
          @aggregate.value_object(type)
        end
      end

      # Array[...] of individually-escaped literals — same escaping
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
