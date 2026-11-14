require "sqlite3"
require "tmpdir"
require "hecks/hecks/adapters/ledger_weighing"
require "hecks/hecks/adapters/ledger_reclaiming"

# A small SQLite file shaped like the AgentRun journal: `agent_run_entries` and the checkpoint
# row that says how far it was projected and how far it was compacted.
module LedgerScratch
  Keeping = Hecks::Adapters::LedgerKeeping

  # The world row the registry answers for any verb.
  World = Struct.new(:row) { def for_verb(_verb) = row }

  # Builds the file with `rows` journal entries, all projected and none compacted.
  #
  # @return [String] the file's path, in a directory the example removes
  def scratch_ledger(rows)
    path = File.join(Dir.mktmpdir("ledger-care"), "agent_run.db")
    db = SQLite3::Database.new(path)
    db.execute("CREATE TABLE agent_run_entries (sequence INTEGER PRIMARY KEY AUTOINCREMENT, state TEXT)")
    db.execute("CREATE TABLE hecks_checkpoints (aggregate_table TEXT PRIMARY KEY, last_sequence INTEGER DEFAULT 0, " \
               "compacted_through INTEGER DEFAULT 0)")
    db.transaction { rows.times { db.execute("INSERT INTO agent_run_entries (state) VALUES (?)", ["x" * 400]) } }
    db.execute("INSERT INTO hecks_checkpoints VALUES ('agent_run', ?, 0)", [rows])
    db.close
    path
  end

  # @return [Keeping::Database] the file under a wait of `wait` seconds
  def ledger_at(path, wait: 0.2) = Keeping::Database.new(path, table: "agent_run", wait: wait)

  # Holds the write lock on the file in another connection until the block ends.
  def while_held(path, mode: "IMMEDIATE")
    other = SQLite3::Database.new(path)
    other.execute("BEGIN #{mode} TRANSACTION")
    yield
  ensure
    other&.close
  end

  # A registry that names a Tickets `ledger_care` row and a root, with the AgentRun file found at
  # `database`.
  def registry_over(database, entries: 1)
    row = { entries: entries, wait_seconds: 0.2 }
    allow(Keeping::Ledger).to receive(:database).and_return(database)
    instance_double(Hecks::Runtime::Registry, root: "/domains/hecks", world: World.new(row))
  end

  # @return [Hecks::Adapters::LedgerWeighing] the beat's adapter over that registry
  def weighing_over(database, entries:)
    Hecks::Adapters::LedgerWeighing.new(registry: registry_over(database, entries: entries))
  end
end
