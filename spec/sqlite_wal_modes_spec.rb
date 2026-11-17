require "spec_helper"
require "tmpdir"
require "sqlite3"
require "hecks/adapters/driven/sqlite"

RSpec.describe Hecks::Adapters::Sqlite::ConnectionPragmas, "#checkpoint!" do
  let(:dir) { Dir.mktmpdir("wal-modes") }

  after { FileUtils.rm_rf(dir) }

  it "leaves a delete-mode file alone" do
    db = SQLite3::Database.new(File.join(dir, "ledger.db"))
    described_class.new(db, journal_mode: "delete").apply!
    expect(db.get_first_value("PRAGMA journal_mode")).to eq("delete")
  end

  it "does not checkpoint an in-memory store" do
    expect(described_class.new(SQLite3::Database.new(":memory:")).checkpoint!).to be(false)
  end
end
