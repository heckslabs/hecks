require "spec_helper"
require "tmpdir"
require "sqlite3"

# Several processes write one ledger file at once, so two writers on a file must both finish, a
# reader must not wait for a writer, and the file's journal mode is the world's to name.
RSpec.describe "Hecks::Adapters::Sqlite with several writers on one file" do
  around do |example|
    @dir = Dir.mktmpdir("hecks-sqlite-writers-")
    example.run
  ensure
    FileUtils.remove_entry(@dir) if @dir
  end

  before(:context) { @aggregate = boot_in_memory.registry.bluebook("Pizzas").aggregate("Order") }

  def path = File.join(@dir, "ledger.db")

  def adapter(**settings)
    Hecks::Adapters::Sqlite.new(aggregate: @aggregate, settings: { database: "ledger.db", **settings }, root: @dir)
  end

  def raw = SQLite3::Database.new(path)

  def journal_mode
    db = raw
    db.get_first_value("PRAGMA journal_mode")
  ensure
    db&.close
  end

  def write_notes(store, count)
    db = store.instance_variable_get(:@db)
    count.times { store.transaction { db.execute("INSERT INTO hecks_checkpoints DEFAULT VALUES") } }
  end

  def two_writers
    stores = Array.new(2) { adapter }
    stores.map { |store| Thread.new { write_notes(store, 15) } }.each(&:join)
    stores
  end

  def checkpoint_count
    db = raw
    db.get_first_value("SELECT count(*) FROM hecks_checkpoints")
  ensure
    db&.close
  end

  it "keeps the file in WAL mode by default" do
    adapter
    expect(journal_mode).to eq("wal")
  end

  it "keeps the rollback journal when the world names journal_mode delete" do
    adapter(journal_mode: "delete")
    expect(journal_mode).to eq("delete")
  end

  it "refuses a journal mode it does not know, by name" do
    expect { adapter(journal_mode: "off; DROP TABLE x") }.to raise_error(ArgumentError, /journal_mode must be/)
  end

  it "lets two writers on one file both finish", :aggregate_failures do
    expect { two_writers }.not_to raise_error
    expect(checkpoint_count).to eq(30)
  end

  # What a reader with no wait at all counts while a writer's transaction is open.
  def count_read_during_write
    store = adapter
    store.transaction do
      write_notes(store, 1)
      reader = raw
      reader.busy_timeout = 0
      return reader.get_first_value("SELECT count(*) FROM hecks_checkpoints")
    end
  end

  it "lets a reader read at once while a writer holds its transaction open" do
    expect(count_read_during_write).to eq(0)
  end

  it "reads a plain copy of the file once its connections are closed" do
    store = adapter
    write_notes(store, 3)
    store.instance_variable_get(:@db).close
    FileUtils.cp(path, File.join(@dir, "copy.db"))
    expect(SQLite3::Database.new(File.join(@dir, "copy.db")).get_first_value("SELECT count(*) FROM hecks_checkpoints")).to eq(3)
  end
end
