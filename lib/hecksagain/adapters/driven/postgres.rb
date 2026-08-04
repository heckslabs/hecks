require "pg"
require "json"

require_relative "sql_query_builder"
require_relative "postgres/lineage"
require_relative "postgres/lineage_manager"
require_relative "../../ports/persistence/append_only"
require_relative "../../runtime/event"
require_relative "../../runtime/instance"
require_relative "../../runtime/registry"

module Hecksagain
  module Adapters
    # The first enforcement-grade persistence adapter — and the only one
    # that declares the LINEAGE capability: it may act on shape drift
    # (translate, fork, merge) where every other adapter can only refuse
    # toward it.
    #
    # Storage model (see postgres/lineage.rb for the DDL):
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
    class Postgres
      include SqlQueryBuilder

      attr_reader :aggregate

      # The capability idiom: only Postgres answers true, and only
      # Postgres carries an era_check! for the boot gate to delegate to.
      def self.lineage_capable? = true

      def self.era_check!(registry:, bluebook:, current_text:, settings:, directory: nil)
        LineageManager.check!(
          registry: registry, bluebook: bluebook, current_text: current_text,
          settings: settings, directory: directory
        )
      end

      def self.connect_for(name, settings)
        declared = settings[:database] || settings["database"]
        if declared.to_s.empty?
          raise Runtime::WiringError,
                "#{name} binds Postgres, which needs a database connection, " \
                "but its world declares no \"database\"."
        end

        if declared.start_with?("postgres://", "postgresql://")
          PG.connect(declared)
        else
          PG.connect(dbname: declared)
        end
      rescue PG::Error => error
        raise Runtime::WiringError,
              "cannot bind Postgres at #{declared} for #{name}: #{error.message.strip}"
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
        @lineage.ensure_first_head!(table) if @era == 1
        create_event_table!
      end

      def table = @aggregate.storage_name

      def find(id)
        result = @db.exec_params(%(SELECT id, state FROM #{quoted_head} WHERE id = $1), [id.to_s])
        return nil if result.ntuples.zero?

        instance(result[0])
      end

      def all
        @db.exec(%(SELECT id, state FROM #{quoted_head} ORDER BY id)).map { |row| instance(row) }
      end

      def count = @db.exec(%(SELECT COUNT(*) FROM #{quoted_head}))[0]["count"].to_i

      # HELD FOR THE WHOLE TRANSACTION, not just around the INSERT — the
      # ordinal is assigned by the column's own `nextval()` default, inside
      # this same statement, so the lock has to already be held before that
      # default evaluates. A DIFFERENT key from `mint_era!`/`merge_tail!`'s
      # `hecks_eras:domain` : this serializes plain writes against EACH
      # OTHER, never against a mint. See postgres/lineage.rb's own comment
      # for why only that half of the race is closed.
      def append(entry)
        @db.transaction do
          @db.exec_params(
            "SELECT pg_advisory_xact_lock(hashtext('hecks_ordinal:' || $1))",
            [@lineage.domain]
          )
          @db.exec_params(
            "INSERT INTO #{@lineage.quoted_journal} (era, aggregate, aggregate_id, operation, state, mirrors) " \
            "VALUES ($1, $2, $3, $4, $5, $6)",
            [@era, table, entry.id, entry.operation,
             entry.state && JSON.generate(entry.state), entry.mirrors && JSON.generate(entry.mirrors)]
          )
        end
        entry
      end

      # The head is DERIVED — projecting is reading, so there is nothing
      # to write here. The instance is still built (and validated) so a
      # save returns what every other adapter returns.
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

      private

      # ── SqlQueryBuilder's dialect hooks ─────────────────────────────

      def select_list = "id, state"
      def from_relation = quoted_head
      def dialect_name = "Postgres"
      def empty_in_clause = "FALSE"

      def placeholder(binds, value)
        binds << value
        "$#{binds.size}"
      end

      def contains_clause(expression, placeholder)
        "position(#{placeholder} in #{expression}) > 0"
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

      def numeric_field?(field)
        name, *path = field.to_s.split(".")
        attribute = @aggregate.attribute(name)
        return %w[Integer Float].include?(attribute&.type.to_s) if path.empty? && attribute && !value_object?(attribute)
        return false unless attribute && value_object?(attribute)

        object = @aggregate.value_object(attribute.type)
        member = path.first || object.attributes.find { |candidate| %w[Integer Float].include?(candidate.type) }&.name || "value"
        %w[Integer Float].include?(object.attribute(member.to_sym)&.type.to_s)
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
    end
  end
end
