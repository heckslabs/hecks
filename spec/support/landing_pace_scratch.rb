require "json"
require "sqlite3"
require "tmpdir"
require "hecks/hecks/adapters/landing_pace_reading"

# A small SQLite file shaped like a ledger's event table, holding a few days of landings, and the
# measure the `Pace` adapter takes of it.
module LandingPaceScratch
  # Each event: name, aggregate, record, branch (nil when the event names none), time.
  ROWS = [
    ["LandingSubmitted", "Delivery::Landing", "sha-a", "a", "2026-11-01T10:00:00Z"],
    ["CarryRequested",   "Delivery::Landing", "run-1", "a", "2026-11-01T10:00:10Z"],
    ["LandingRefused",   "Delivery::Landing", "run-1", nil, "2026-11-01T10:01:00Z"],
    ["CarryRequested",   "Delivery::Landing", "run-2", "a", "2026-11-01T10:04:00Z"],
    ["BranchLanded",     "Delivery::Landing", "run-2", "a", "2026-11-01T10:05:00Z"],
    ["FinishRequested",  "Hecks::Landing",    "run-3", nil, "2026-11-01T11:00:00Z"],
    ["BranchLanded",     "Hecks::Landing",    "run-3", "b", "2026-11-01T11:00:30Z"],
    ["BranchLanded",     "Delivery::Landing", "run-4", "c", "2026-11-03T09:00:00Z"],
    ["BranchLanded",     "Hecks::Shipment",   "run-5", "d", "2026-11-03T09:30:00Z"]
  ].freeze

  # Branch `a` asked for again after it landed, and landed five seconds later.
  AGAIN = [
    ["LandingRequested", "Delivery::Landing", "run-6", "a", "2026-11-01T12:00:00Z"],
    ["BranchLanded",     "Delivery::Landing", "run-6", "a", "2026-11-01T12:00:05Z"]
  ].freeze

  INSERT = "INSERT INTO events (name, aggregate, aggregate_id, payload, occurred_at) VALUES (?, ?, ?, ?, ?)".freeze

  # @return [String] the path of a new file holding `rows`, in a temporary directory
  def scratch_events(rows)
    path = File.join(Dir.mktmpdir("landing-pace"), "ledger.db")
    db = SQLite3::Database.new(path)
    db.execute("CREATE TABLE events (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT, aggregate TEXT, " \
               "aggregate_id TEXT, payload TEXT, occurred_at TEXT)")
    rows.each { |row| db.execute(INSERT, stored(row)) }
    db.close
    path
  end

  # @return [String] the measure of a ledger holding `rows`, over the last `days` days
  def pace_of(rows, days: 100_000)
    allow(Hecks::Adapters::LandingPaceReading::Ledger).to receive(:path).and_return(scratch_events(rows))
    Hecks::Adapters::LandingPaceReading.new.pace(days: days)[:text]
  end

  private

  def stored(row)
    name, aggregate, record, branch, at = row
    [name, aggregate, record, JSON.generate(branch ? { branch: { value: branch } } : {}), at]
  end
end
