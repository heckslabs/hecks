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

  # Loads and memoizes Banking's own bluebook.
  #
  # Banking's IR only — no hecksagon, no boot: every adapter here is
  # built directly from `aggregate:`, the same way the sibling adapter
  # specs build theirs.
  #
  # @return [Bluebook::Chapter] Banking's declared chapter
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
  # @param name [String] the aggregate's declared name, such as `"Account"`
  # @return [Bluebook::Aggregate, nil] the aggregate from Banking's bluebook, or `nil` if none
  #   is declared by that name
  def aggregate(name) = bluebook.aggregate(name)

  # Builds one live `Runtime::Instance` per row in `SEEDS`.
  #
  # @return [Array<Runtime::Instance>] one instance per seed, with every field set from the
  #   seed's raw fixture value via `Runtime::Value.for`
  def instances
    SEEDS.map do |name, id, fields|
      aggregate = aggregate(name)
      instance = Hecks::Runtime::Instance.new(aggregate: aggregate, id: id)
      fields.each { |field, value| instance[field] = Hecks::Runtime::Value.for(aggregate, field, value) }
      instance
    end
  end

  # Reads and parses a committed fixture file.
  #
  # @param relative [String] path to a fixture file, relative to `DIR`
  # @return [Object] the parsed JSON value (a Hash or an Array, per `JSON.parse`) read from
  #   that path
  def read_json(relative) = JSON.parse(File.read(File.join(DIR, relative)))

  # ── restoring each committed fixture into a live adapter ─────────────

  # Copies a committed Heki fixture into `dir` and builds a live adapter over the copy.
  #
  # @param aggregate [Bluebook::Aggregate] the aggregate whose committed fixture to restore
  # @param dir [String] directory to copy the fixture's `.heki`/`.heki.journal` files into
  # @return [Adapters::Heki] a Heki adapter rooted at `dir`, backed by the copied files
  def heki_adapter(aggregate, dir)
    %w[heki heki.journal].each do |extension|
      FileUtils.cp(File.join(DIR, "heki", "#{aggregate.storage_name}.#{extension}"), dir)
    end
    Hecks::Adapters::Heki.new(aggregate: aggregate, settings: { dir: "." }, root: dir)
  end

  # Creates (if missing) a SQLite database from the committed schema and builds an adapter
  # over it.
  #
  # @param aggregate [Bluebook::Aggregate] the aggregate the adapter persists
  # @param dir [String] directory to create or reuse `banking.sqlite3` in
  # @return [Adapters::Sqlite] a Sqlite adapter rooted at `dir`
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

  # Builds a fake `D1::Connection`, backed by a real in-memory SQLite database.
  #
  # D1 is SQLite behind an HTTP transport — the same stand-in
  # `spec/adapters/driven/d1_spec.rb` uses: a real in-memory SQLite
  # database answering `Connection`'s own four methods.
  #
  # @return [Object] an anonymous stand-in for `Adapters::D1::Connection`, answering
  #   `#execute`, `#get_first_row`, and `#get_first_value` against the in-memory database
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

  # Runs the block with `Adapters::D1::Connection.new` stubbed to return `connection`, so any
  # `D1.new` inside the block picks it up instead of opening a real HTTP connection.
  #
  # @param connection [Object] the connection every `D1.new` call in the block should receive
  # @yieldreturn [Object] the block's own result, returned unchanged
  # @return [Object] the block's return value
  def with_d1_connection(connection)
    klass = Hecks::Adapters::D1::Connection
    klass.define_singleton_method(:new) { |**| connection }
    yield
  ensure
    klass.singleton_class.send(:remove_method, :new) if klass.singleton_class.method_defined?(:new, false)
  end

  # Builds a D1 adapter over a fake connection, preloaded with the committed fixture rows.
  #
  # @param aggregate [Bluebook::Aggregate] the aggregate the adapter persists
  # @param connection [Object] the connection to use in place of a real D1 HTTP connection;
  #   defaults to a fresh `#fake_d1_connection`
  # @return [Adapters::D1] a D1 adapter backed by `connection`
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

  # Allocates an adapter without calling `initialize`, so `#decode` can run with no connection.
  #
  # The Codec alone, no connection: `decode(row)` only reads `@aggregate`.
  # Lets a default (non-io) run pin what Postgres/PostgresEra make of the
  # exact rows `pg` handed back when the fixture was written.
  #
  # @param klass [Class] the adapter class to allocate, such as `Adapters::Postgres`
  # @param aggregate [Bluebook::Aggregate] the aggregate to set as the allocated adapter's
  #   `@aggregate`
  # @return [Object] an allocated, uninitialized instance of `klass` with `@aggregate` set
  def codec(klass, aggregate)
    klass.allocate.tap { |adapter| adapter.instance_variable_set(:@aggregate, aggregate) }
  end

  # Builds a Postgres adapter over `database`, preloaded with the committed fixture rows.
  #
  # @param aggregate [Bluebook::Aggregate] the aggregate the adapter persists
  # @param database [String] name of the Postgres database to connect to
  # @return [Adapters::Postgres] a Postgres adapter over `database`
  def postgres_adapter(aggregate, database)
    adapter = Hecks::Adapters::Postgres.new(aggregate: aggregate, settings: { database: database })
    connection = adapter.instance_variable_get(:@db)
    fixture = read_json("postgres/rows.json").fetch(aggregate.storage_name)
    fixture.fetch("head").each { |row| insert_pg_row(connection, aggregate.storage_name, row) }
    fixture.fetch("entries").each { |row| insert_pg_row(connection, "#{aggregate.storage_name}_entries", row) }
    adapter
  end

  # Builds a PostgresEra adapter over `database`, preloaded with the committed fixture's
  # journal and head-snapshot rows.
  #
  # @param aggregate [Bluebook::Aggregate] the aggregate the adapter persists
  # @param database [String] name of the Postgres database to connect to
  # @return [Adapters::PostgresEra] a PostgresEra adapter over `database`
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

  # Inserts one row into a SQLite-shaped connection.
  #
  # @param connection [Object] a SQLite connection responding to `#execute`, such as the fake
  #   D1 connection's own in-memory database
  # @param table [String] name of the table to insert into
  # @param row [Hash] column-name-to-value pairs to insert
  # @return [void]
  def insert_row(connection, table, row)
    columns = row.keys.map { |column| %("#{column}") }.join(", ")
    slots = Array.new(row.size, "?").join(", ")
    connection.execute(%(INSERT INTO "#{table}" (#{columns}) VALUES (#{slots})), row.values)
  end

  # Inserts one row into a Postgres connection.
  #
  # @param connection [PG::Connection] the Postgres connection to insert through
  # @param table [String] name of the table to insert into
  # @param row [Hash] column-name-to-value pairs to insert
  # @param quoted [Boolean] whether `table` is already a quoted identifier, skipping
  #   `PG::Connection.quote_ident`
  # @return [void]
  def insert_pg_row(connection, table, row, quoted: false)
    target = quoted ? table : PG::Connection.quote_ident(table)
    columns = row.keys.map { |column| PG::Connection.quote_ident(column) }.join(", ")
    slots = row.keys.each_index.map { |index| "$#{index + 1}" }.join(", ")
    connection.exec_params("INSERT INTO #{target} (#{columns}) VALUES (#{slots})", row.values)
  end
end
