require "spec_helper"
require "tmpdir"
require "sqlite3"
require "hecks/adapters/driving/resident/stores"

# A resident's forked child closes the stores its line opened the moment its command ends (ADR
# 0201), so a child that is slow to leave holds no SQLite file and no lock on one. The stores are
# recorded as they open. Nothing here changes `SQLite3::Database` itself: the recorders are
# prepended to classes of the spec's own.
RSpec.describe Hecks::Adapters::Driving::Resident::Stores do
  let(:recorded_database) { Class.new(SQLite3::Database) { prepend Hecks::Adapters::Driving::Resident::Stores::Sqlite } }
  let(:connection) do
    Struct.new(:ended) do
      def finished? = ended
      def finish = (self.ended = true)
    end
  end

  around do |example|
    Dir.mktmpdir("hst") do |dir|
      @file = File.join(dir, "store.db")
      example.run
    ensure
      described_class.opened.clear
    end
  end

  # A store a line opened and left holding the write lock, as a command that ended mid-write does.
  def held_store
    recorded_database.new(@file).tap { |db| db.execute("BEGIN IMMEDIATE TRANSACTION") }
  end

  # @return [Boolean] whether another connection can take the file's write lock at once
  def free?
    other = SQLite3::Database.new(@file)
    other.execute("BEGIN IMMEDIATE TRANSACTION")
    true
  rescue SQLite3::BusyException
    false
  ensure
    other&.close
  end

  it "records a SQLite database as the line opens it" do
    db = recorded_database.new(@file)
    expect(described_class.opened).to eq([db])
  end

  it "holds the file against other lines while the store is open" do
    held_store
    expect(free?).to be(false)
  end

  it "closes the store, and frees the file, when the command ends", :aggregate_failures do
    db = held_store
    described_class.close
    expect(db).to be_closed
    expect(free?).to be(true)
  end

  it "forgets the stores it closed" do
    held_store
    described_class.close
    expect(described_class.opened).to be_empty
  end

  it "records a Postgres connection as the line starts it" do
    made = connection.new(false)
    pg = Class.new { define_singleton_method(:connect_start) { |*| made } }
    pg.singleton_class.prepend(described_class::Postgres)
    expect(pg.connect_start("host=x")).to be(described_class.opened.first)
  end

  it "finishes a Postgres connection that is still open" do
    described_class.opened << (open = connection.new(false))
    described_class.close
    expect(open.ended).to be(true)
  end

  it "passes over a store that refuses to close, and closes the rest", :aggregate_failures do
    broken = Object.new.tap { |store| def store.closed? = raise(IOError, "gone") }
    described_class.opened.push(broken, db = recorded_database.new(@file))
    expect { described_class.close }.not_to raise_error
    expect(db).to be_closed
  end

  it "starts recording on the gems' own classes, in the child", :aggregate_failures do
    stub_const("SQLite3::Database", Class.new)
    stub_const("PG::Connection", Class.new)
    described_class.record
    expect(SQLite3::Database.ancestors).to include(described_class::Sqlite)
    expect(PG::Connection.singleton_class.ancestors).to include(described_class::Postgres)
  end
end
