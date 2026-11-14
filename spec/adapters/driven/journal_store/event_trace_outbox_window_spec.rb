# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "json"
require "sqlite3"
require "hecks/hecks/adapters/journal_store"

# A trace of the newest events reads the outbox rows of its own window. An aggregate that has lived
# a long time owns thousands of old rows, and the trace neither returns nor parses them.
RSpec.describe Hecks::Adapters::JournalStore::Readings::EventTrace::SqliteReader do
  def old_rows = 6000

  def outbox_row(db, index, time)
    event = JSON.generate(name: "Moved", id: "run-1", occurred_at: time, payload: { n: index })
    db.execute("INSERT INTO hecks_outbox (consumer, event, enqueued_at) VALUES (?, ?, ?)", ["policy:A", event, time])
  end

  def lay_out(path)
    db = SQLite3::Database.new(path)
    db.execute("CREATE TABLE events (id INTEGER PRIMARY KEY, name TEXT, aggregate TEXT, aggregate_id TEXT, " \
               "payload TEXT, occurred_at TEXT)")
    db.execute("CREATE TABLE hecks_outbox (id INTEGER PRIMARY KEY AUTOINCREMENT, consumer TEXT, status TEXT " \
               "DEFAULT 'delivered', error TEXT, event TEXT, enqueued_at TEXT)")
    db.transaction do
      old_rows.times { |index| outbox_row(db, index, "2026-01-01T00:00:00Z") }
      3.times { |index| outbox_row(db, old_rows + index, "2026-11-14T06:00:00Z") }
    end
    db.close
  end

  def recent_event = { "id" => 1, "name" => "Moved", "aggregate_id" => "run-1", "occurred_at" => "2026-11-14T06:00:00Z" }

  def read_rows(path)
    reader = described_class.open(path)
    reader.outbox_for([recent_event])
  ensure
    reader&.close
  end

  around do |example|
    Dir.mktmpdir("outbox-window-") do |dir|
      @path = File.join(dir, "trace.db")
      lay_out(@path)
      example.run
    end
  end

  it "answers the rows of the window and none of the older ones" do
    expect(read_rows(@path).size).to eq(3)
  end

  it "reads the rows from the end of the table", :aggregate_failures do
    ids = read_rows(@path).map { |row| row["id"] }
    expect(ids.min).to be > old_rows
    expect(ids.max).to eq(old_rows + 3)
  end

  def floor_with_count
    db = SQLite3::Database.new(@path, readonly: true)
    db.results_as_hash = true
    count = 0
    run = ->(sql, binds) { (count += 1) && db.execute(sql, binds) }
    [Hecks::Adapters::JournalStore::Readings::EventTrace::OutboxFloor.new(run).before([recent_event]), count]
  end

  it "finds the floor in a handful of reads, not one per row", :aggregate_failures do
    floor, count = floor_with_count
    expect(floor).to eq(old_rows + 1)
    expect(count).to be < 40
  end
end
