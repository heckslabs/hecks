require "spec_helper"
require "tmpdir"
require "sqlite3"
require "hecks/adapters/driven/sqlite"

# Helpers for the groups below: a temp ledger file and a way to grow its log.
module WalBoundHelpers
  def connect
    SQLite3::Database.new(path).tap do |db|
      db.busy_handler_timeout = 200
      db.results_as_hash = true
    end
  end

  # Grows the log with autocheckpoint off.
  def bloat
    db = connect
    db.execute("PRAGMA journal_mode = wal")
    db.execute("PRAGMA wal_autocheckpoint = 0")
    db.execute("CREATE TABLE t (id INTEGER PRIMARY KEY, v TEXT)")
    300.times { db.execute("INSERT INTO t (v) VALUES (?)", ["x" * 4000]) }
    db
  end

  def open_with_pragmas
    connect.tap { |db| Hecks::Adapters::Sqlite::ConnectionPragmas.new(db).apply! }
  end

  def reading_connection
    connect.tap { |db| db.get_first_value("SELECT count(*) FROM t") }
  end
end

RSpec.describe Hecks::Adapters::Sqlite::ConnectionPragmas, "#apply!" do
  include WalBoundHelpers

  let(:dir) { Dir.mktmpdir("wal-bound") }
  let(:path) { File.join(dir, "ledger.db") }

  after { FileUtils.rm_rf(dir) }

  it "truncates an oversized log when the store opens", :aggregate_failures do
    bloat
    expect(File.size("#{path}-wal")).to be > 1_000_000
    open_with_pragmas.close
    expect(File.size("#{path}-wal")).to eq(0)
  end

  it "bounds the log while a long-lived reader holds the file open" do
    bloat
    reading_connection
    open_with_pragmas.close
    expect(File.size("#{path}-wal")).to be < 2_000_000
  end

  it "sets the size limit and the autocheckpoint", :aggregate_failures do
    db = open_with_pragmas
    expect(db.get_first_value("PRAGMA journal_size_limit")).to eq(described_class::JOURNAL_SIZE_LIMIT)
    expect(db.get_first_value("PRAGMA wal_autocheckpoint")).to eq(described_class::WAL_AUTOCHECKPOINT)
  end
end
