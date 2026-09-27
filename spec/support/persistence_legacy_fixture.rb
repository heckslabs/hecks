require "hecks"
require "json"
require "fileutils"

# Seeds and adapter builders shared by `bin/regenerate_persistence_legacy_fixtures` and
# `spec/ports/persistence_legacy_decode_spec.rb`, over `examples/banking`.
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

  # Banking's IR only: no hecksagon, no boot; adapters are built straight from `aggregate:`.
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

  def aggregate(name) = bluebook.aggregate(name)

  def instances
    SEEDS.map do |name, id, fields|
      aggregate = aggregate(name)
      instance = Hecks::Runtime::Instance.new(aggregate: aggregate, id: id)
      fields.each { |field, value| instance[field] = Hecks::Runtime::Value.for(aggregate, field, value) }
      instance
    end
  end

  def read_json(relative) = JSON.parse(File.read(File.join(DIR, relative)))

  def heki_adapter(aggregate, dir)
    %w[heki heki.journal].each do |extension|
      FileUtils.cp(File.join(DIR, "heki", "#{aggregate.storage_name}.#{extension}"), dir)
    end
    Hecks::Adapters::Heki.new(aggregate: aggregate, settings: { dir: "." }, root: dir)
  end

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

  # In-memory SQLite answering `Connection`'s four methods, as `d1_spec.rb` does.
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

  def with_d1_connection(connection)
    klass = Hecks::Adapters::D1::Connection
    klass.define_singleton_method(:new) { |**| connection }
    yield
  ensure
    klass.singleton_class.send(:remove_method, :new) if klass.singleton_class.method_defined?(:new, false)
  end

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

  # The Codec alone: `decode(row)` reads only `@aggregate`, so no connection is needed.
  def codec(klass, aggregate)
    klass.allocate.tap { |adapter| adapter.instance_variable_set(:@aggregate, aggregate) }
  end

  def postgres_adapter(aggregate, database)
    adapter = Hecks::Adapters::Postgres.new(aggregate: aggregate, settings: { database: database })
    connection = adapter.instance_variable_get(:@db)
    fixture = read_json("postgres/rows.json").fetch(aggregate.storage_name)
    fixture.fetch("head").each { |row| insert_pg_row(connection, aggregate.storage_name, row) }
    fixture.fetch("entries").each { |row| insert_pg_row(connection, "#{aggregate.storage_name}_entries", row) }
    adapter
  end

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

  def insert_row(connection, table, row)
    columns = row.keys.map { |column| %("#{column}") }.join(", ")
    slots = Array.new(row.size, "?").join(", ")
    connection.execute(%(INSERT INTO "#{table}" (#{columns}) VALUES (#{slots})), row.values)
  end

  def insert_pg_row(connection, table, row, quoted: false)
    target = quoted ? table : PG::Connection.quote_ident(table)
    columns = row.keys.map { |column| PG::Connection.quote_ident(column) }.join(", ")
    slots = row.keys.each_index.map { |index| "$#{index + 1}" }.join(", ")
    connection.exec_params("INSERT INTO #{target} (#{columns}) VALUES (#{slots})", row.values)
  end
end
