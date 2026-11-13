require "spec_helper"
require "tmpdir"
require "sqlite3"
require_relative "../../../support/thread_parking"

# Several processes share one ledger file, so a writer that finds it held waits for it, and a
# writer whose commit cannot get the file lets go of it instead of holding it until it exits.
RSpec.describe "Hecks::Adapters::Sqlite under a held write lock" do
  around do |example|
    @dir = Dir.mktmpdir("hecks-sqlite-lock-")
    example.run
  ensure
    FileUtils.remove_entry(@dir) if @dir
  end

  before(:context) { @aggregate = boot_in_memory.registry.bluebook("Pizzas").aggregate("Order") }

  before { seed! }

  def path = File.join(@dir, "ledger.db")

  def raw = SQLite3::Database.new(path)

  # A table of its own beside the adapter's, with rows enough that a read can stop part way.
  def seed!
    db = raw
    db.execute("CREATE TABLE notes (body TEXT)")
    3.times { |index| db.execute("INSERT INTO notes (body) VALUES (?)", ["note #{index}"]) }
  ensure
    db&.close
  end

  def adapter(**settings)
    Hecks::Adapters::Sqlite.new(aggregate: @aggregate, settings: { database: "ledger.db", **settings }, root: @dir)
  end

  def write_note(store)
    store.transaction { store.instance_variable_get(:@db).execute("INSERT INTO notes (body) VALUES ('mine')") }
  end

  # Another process's write lock, held until the caller commits and closes it.
  def hold_write_lock
    holder = raw
    holder.execute("BEGIN EXCLUSIVE")
    holder
  end

  def let_go(holder)
    holder.execute("COMMIT")
    holder.close
  end

  # A writer on its own thread, parked in its wait for the held file. A wait that held every
  # other thread still would let this thread run only once the writer had finished.
  def parked_writer
    writer = Thread.new { write_note(adapter) }
    ThreadParking.wait_until_parked(writer)
  end

  def notes_read_at_once
    reader = raw
    reader.busy_timeout = 0
    reader.get_first_value("SELECT count(*) FROM notes")
  ensure
    reader&.close
  end

  it "waits for a held write lock, letting other threads run, and writes once it is let go", :aggregate_failures do
    holder = hold_write_lock
    writer = parked_writer
    expect(writer).to be_alive
    let_go(holder)
    expect([writer.join, notes_read_at_once].last).to eq(4)
  end

  it "fails by name when the lock is held past the busy timeout" do
    holder = hold_write_lock
    expect { adapter(busy_timeout_ms: 100) }.to raise_error(SQLite3::BusyException)
  ensure
    let_go(holder)
  end

  # A reader part way through a statement holds the file, so the commit cannot take it.
  def write_while_read_is_open(store)
    reader = raw
    statement = reader.prepare("SELECT * FROM notes")
    statement.step
    write_note(store)
  rescue SQLite3::BusyException
    :busy
  ensure
    statement&.close
    reader&.close
  end

  it "rolls back a commit that found the file busy, so no lock outlives it", :aggregate_failures do
    store = adapter(busy_timeout_ms: 100)
    expect(write_while_read_is_open(store)).to eq(:busy)
    expect(store.instance_variable_get(:@db).transaction_active?).to be(false)
    expect(notes_read_at_once).to eq(3)
  end
end
