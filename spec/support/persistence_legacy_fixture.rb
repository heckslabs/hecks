require "hecks"
require "hecks/persistence_legacy_fixture"
require "json"
require "fileutils"

# Adapter builders shared by `spec/ports/persistence_legacy_decode_spec.rb` and its neighbours,
# over the fixtures `Hecks::PersistenceLegacyFixture` seeds and writes
# (`hecks regenerate_legacy_fixtures`).
module PersistenceLegacyFixture
  ROOT = Hecks::PersistenceLegacyFixture::ROOT
  DIR  = Hecks::PersistenceLegacyFixture::DIR
  SEEDS = Hecks::PersistenceLegacyFixture::SEEDS

  module_function

  def bluebook = Hecks::PersistenceLegacyFixture.bluebook

  def aggregate(name) = Hecks::PersistenceLegacyFixture.aggregate(name)

  def instances = Hecks::PersistenceLegacyFixture.instances

  def fake_d1_connection = Hecks::PersistenceLegacyFixture.fake_d1_connection

  def with_d1_connection(connection, &) = Hecks::PersistenceLegacyFixture.with_d1_connection(connection, &)

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
