require "hecks"
require "json"
require "fileutils"

# The legacy persistence baseline (Phase 2, Track A, PR A1) — shared by
# `bin/regenerate_persistence_legacy_fixtures` (which writes the committed
# fixtures under spec/fixtures/persistence_legacy/ by really running each
# adapter) and `spec/ports/persistence_legacy_decode_spec.rb` (which reads
# them back through today's adapters and pins exactly what each one
# decodes, key-type inconsistencies included).
#
# One seed set, one place: the script and the spec must agree on which
# aggregates/ids the fixtures hold, so neither re-types them.
#
# The shapes, all from `examples/banking` (a real, fuzzed domain — no new
# bluebook):
# - Account: `balance`/`fees_cents`/`interest_cents` (Money — a nested
#   multi-field value object), `ledger` (list_of LedgerEntry — entities,
#   each holding its own nested Money/Narrative/LedgerSequence), `customer`
#   (a reference), `status` (lifecycle), `customer_status` (projects).
# - CardPayment: `tags` (list_of Tag — a list of value objects), `account`
#   (reference), `disputed_by` (an optional reference, left nil), `status`
#   (lifecycle), `account_status` (projects).
module PersistenceLegacyFixture
  ROOT = File.expand_path("../..", __dir__)
  DIR  = File.join(ROOT, "spec/fixtures/persistence_legacy").freeze

  SEEDS = [
    [
      "Account", "ACC-1",
      {
        number:          { value: "ACC-1" },
        customer:        "CUST-1",
        balance:         { cents: 1250, currency: "USD" },
        kind:            { name: "current" },
        daily_limit:     { cents: 500 },
        ledger:          [
          { sequence: { value: 1 }, amount: { cents: 1000, currency: "USD" }, narrative: { text: "opening" },
            direction: { value: "credit" }, state: "posted" },
          { sequence: { value: 2 }, amount: { cents: 250, currency: "USD" }, narrative: { text: "top up" },
            direction: { value: "credit" }, state: "reversed" }
        ],
        status:          "open",
        customer_status: "active"
      }
    ],
    [
      "CardPayment", "AUTH-1",
      {
        authorisation:  { value: "AUTH-1" },
        account:        "ACC-1",
        amount:         { cents: 300 },
        merchant:       { value: "Cafe" },
        tags:           [{ value: "food" }, { value: "travel" }],
        status:         "authorized",
        account_status: "open"
      }
    ]
  ].freeze

  module_function

  # Banking's IR only — no hecksagon, no boot: every adapter here is
  # built directly from `aggregate:`, the same way the sibling adapter
  # specs build theirs.
  #
  # @return [Bluebook::Chapter] the booted `examples/banking` chapter,
  #   memoized across calls
  def bluebook
    @bluebook ||= begin
      registry = Hecks::Runtime::Registry.new
      Hecks.with_registry(registry) do
        Kernel.load(File.join(ROOT, "lib/hecks/ports/persistence.port"))
        Kernel.load(File.join(ROOT, "lib/hecks/ports/extraction.port"))
        Kernel.load(File.join(ROOT, "lib/hecks/adapters/driven/prism.adapter"))
        folder = Hecks::Adapters::Folder.new
        folder.load_bluebooks(folder.bluebook_directory(File.join(ROOT, "examples/banking/bluebook")))
      end
      registry.bluebook("Banking")
    end
  end

  # Finds one of Banking's declared aggregates by name.
  #
  # @param name [String] the aggregate's declared name ("Account" or
  #   "CardPayment")
  # @return [Bluebook::Aggregate, nil] the aggregate, or nil if none is
  #   declared by that name
  def aggregate(name) = bluebook.aggregate(name)

  # Builds a live `Instance` for each row in `SEEDS`, with every field's
  # raw value coerced through `Value.for`.
  #
  # @return [Array<Runtime::Instance>] one instance per seed, in `SEEDS`
  #   order
  def instances
    SEEDS.map do |name, id, fields|
      aggregate = aggregate(name)
      instance = Hecks::Runtime::Instance.new(aggregate: aggregate, id: id)
      fields.each { |field, value| instance[field] = Hecks::Runtime::Value.for(aggregate, field, value) }
      instance
    end
  end

  # Reads and parses one committed fixture file.
  #
  # @param relative [String] path, relative to `DIR`, to the committed JSON
  #   fixture
  # @return [Hash] the fixture's parsed JSON, string-keyed as `JSON.parse`
  #   produces it
  def read_json(relative) = JSON.parse(File.read(File.join(DIR, relative)))

  # ── restoring each committed fixture into a live adapter ─────────────

  # Copies the committed Heki snapshot and journal files for `aggregate`
  # into `dir` and opens a live adapter over the copies.
  #
  # @param aggregate [Bluebook::Aggregate] the aggregate whose fixture files
  #   to restore
  # @param dir [String] a writable directory to copy the fixture files into
  #   and open the adapter against
  # @return [Adapters::Heki] the adapter, opened over the restored files
  def heki_adapter(aggregate, dir)
    %w[heki heki.journal].each do |extension|
      FileUtils.cp(File.join(DIR, "heki", "#{aggregate.storage_name}.#{extension}"), dir)
    end
    Hecks::Adapters::Heki.new(aggregate: aggregate, settings: { dir: "." }, root: dir)
  end

  # Builds the committed SQLite schema in `dir` on first use, then opens a
  # live adapter against it.
  #
  # @param aggregate [Bluebook::Aggregate] the aggregate to open the adapter
  #   for
  # @param dir [String] a writable directory to hold the SQLite database
  #   file and open the adapter against
  # @return [Adapters::Sqlite] the adapter, opened over the restored database
  def sqlite_adapter(aggregate, dir)
    require "sqlite3"
    path = File.join(dir, "banking.sqlite3")
    unless File.exist?(path)
      db = SQLite3::Database.new(path)
      db.execute_batch(File.read(File.join(DIR, "sqlite/banking.sql")))
      db.close
    end
    Hecks::Adapters::Sqlite.new(aggregate: aggregate, settings: { database: "banking.sqlite3" }, root: dir)
  end

  # D1 is SQLite behind an HTTP transport — the same stand-in
  # `spec/adapters/driven/d1_spec.rb` uses: a real in-memory SQLite
  # database answering `Connection`'s own four methods.
  #
  # @return [Object] an anonymous connection object backed by an in-memory
  #   SQLite database, answering `execute`, `get_first_row` and
  #   `get_first_value`
  def fake_d1_connection
    require "sqlite3"
    db = SQLite3::Database.new(":memory:")
    db.results_as_hash = true
    Class.new do
      def initialize(db) = @db = db
      def execute(sql, binds = []) = @db.execute(sql, binds)
      def get_first_row(sql, binds = []) = execute(sql, binds).first
      def get_first_value(sql, binds = []) = get_first_row(sql, binds)&.values&.first
    end.new(db)
  end

  # Makes `Adapters::D1::Connection.new` return `connection` for the
  # duration of the block, then restores it.
  #
  # @param connection [Object] the stand-in connection to hand back in place
  #   of a real `D1::Connection`
  # @yield runs with `D1::Connection.new` stubbed
  # @return [Object] the block's own return value
  def with_d1_connection(connection)
    klass = Hecks::Adapters::D1::Connection
    klass.define_singleton_method(:new) { |**| connection }
    yield
  ensure
    klass.singleton_class.send(:remove_method, :new) if klass.singleton_class.method_defined?(:new, false)
  end

  # Opens a `D1` adapter over `connection`, seeded from the committed
  # `d1/rows.json` fixture for `aggregate`.
  #
  # @param aggregate [Bluebook::Aggregate] the aggregate to open the adapter
  #   for
  # @param connection [Object] the connection to insert the fixture rows
  #   into and open the adapter against; defaults to a fresh
  #   `#fake_d1_connection`
  # @return [Adapters::D1] the adapter, opened over the seeded connection
  def d1_adapter(aggregate, connection = fake_d1_connection)
    adapter = with_d1_connection(connection) do
      Hecks::Adapters::D1.new(aggregate: aggregate, settings: { account_id: "acc", database_id: "db", api_token: "tok" })
    end
    rows = read_json("d1/rows.json")
    [aggregate.storage_name, "#{aggregate.storage_name}_entries"].each do |table|
      rows.fetch(table).each { |row| insert_row(connection, table, row) }
    end
    adapter
  end

  # The Codec alone, no connection: `decode(row)` only reads `@aggregate`.
  # Lets a default (non-io) run pin what Postgres/PostgresEra make of the
  # exact rows `pg` handed back when the fixture was written.
  #
  # @param klass [Class] the adapter class to allocate, e.g.
  #   `Adapters::Postgres` or `Adapters::PostgresEra`
  # @param aggregate [Bluebook::Aggregate] the aggregate the codec decodes
  #   rows for
  # @return [Object] an instance of `klass`, allocated (never `#initialize`d)
  #   with only `@aggregate` set
  def codec(klass, aggregate)
    klass.allocate.tap { |adapter| adapter.instance_variable_set(:@aggregate, aggregate) }
  end

  # Opens a `Postgres` adapter against `database` and inserts the committed
  # `postgres/rows.json` fixture's head and entry rows for `aggregate`.
  #
  # @param aggregate [Bluebook::Aggregate] the aggregate to open the adapter
  #   for
  # @param database [String] the database name to connect to; must already
  #   exist and be reachable
  # @return [Adapters::Postgres] the adapter, opened over the seeded database
  def postgres_adapter(aggregate, database)
    adapter = Hecks::Adapters::Postgres.new(aggregate: aggregate, settings: { database: database })
    connection = adapter.instance_variable_get(:@db)
    fixture = read_json("postgres/rows.json").fetch(aggregate.storage_name)
    fixture.fetch("head").each { |row| insert_pg_row(connection, aggregate.storage_name, row) }
    fixture.fetch("entries").each { |row| insert_pg_row(connection, "#{aggregate.storage_name}_entries", row) }
    adapter
  end

  # Opens a `PostgresEra` adapter against `database` and inserts the
  # committed `postgres_era/rows.json` fixture's journal and head-snapshot
  # rows for `aggregate`.
  #
  # @param aggregate [Bluebook::Aggregate] the aggregate to open the adapter
  #   for
  # @param database [String] the database name to connect to; must already
  #   exist, be reachable, and carry the era's provisioned schema
  # @return [Adapters::PostgresEra] the adapter, opened over the seeded
  #   database
  def postgres_era_adapter(aggregate, database)
    adapter = Hecks::Adapters::PostgresEra.new(aggregate: aggregate, settings: { database: database })
    connection = adapter.instance_variable_get(:@db)
    lineage = adapter.instance_variable_get(:@lineage)
    fixture = read_json("postgres_era/rows.json").fetch(aggregate.storage_name)
    fixture.fetch("journal").each { |row| insert_pg_row(connection, lineage.quoted_journal, row, quoted: true) }
    snapshot = adapter.send(:quoted_head_snapshot)
    fixture.fetch("head_snapshot").each { |row| insert_pg_row(connection, snapshot, row, quoted: true) }
    adapter
  end

  # Inserts one row into a SQLite (or D1 stand-in) connection's table.
  #
  # @param connection [Object] a connection answering `#execute(sql, binds)`,
  #   real SQLite3 or the `#fake_d1_connection` stand-in
  # @param table [String] the table name, quoted here with double quotes
  # @param row [Hash] column name to value, as inserted in `row.keys` order
  # @return [Object] the connection's own `#execute` return value
  def insert_row(connection, table, row)
    columns = row.keys.map { |column| %("#{column}") }.join(", ")
    slots = Array.new(row.size, "?").join(", ")
    connection.execute(%(INSERT INTO "#{table}" (#{columns}) VALUES (#{slots})), row.values)
  end

  # Inserts one row into a Postgres connection's table.
  #
  # @param connection [PG::Connection] the connection to insert through
  # @param table [String] the table name; quoted here with
  #   `PG::Connection.quote_ident` unless `quoted` is true
  # @param row [Hash] column name to value, as inserted in `row.keys` order
  # @param quoted [Boolean] true if `table` is already a quoted identifier
  #   and should be used as-is
  # @return [PG::Result] the connection's own `#exec_params` return value
  def insert_pg_row(connection, table, row, quoted: false)
    target = quoted ? table : PG::Connection.quote_ident(table)
    columns = row.keys.map { |column| PG::Connection.quote_ident(column) }.join(", ")
    slots = row.keys.each_index.map { |index| "$#{index + 1}" }.join(", ")
    connection.exec_params("INSERT INTO #{target} (#{columns}) VALUES (#{slots})", row.values)
  end
end
