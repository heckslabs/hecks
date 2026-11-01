require "spec_helper"
require "tmpdir"
require "sqlite3"

# An aggregate table made before the aggregate gained attributes: opening the adapter adds a
# nullable column for each attribute the table lacks, keeps the rows already there, and writes.
RSpec.describe "Hecks::Adapters::Sqlite columns for attributes added after the table" do
  around do |example|
    @dir = Dir.mktmpdir("hecks-sqlite-columns-")
    example.run
  ensure
    FileUtils.remove_entry(@dir) if @dir
  end

  before(:context) { @aggregate = boot_in_memory.registry.bluebook("Pizzas").aggregate("Order") }

  # The table as an older aggregate made it: only the id, with one row in it.
  def make_older_table!
    db = SQLite3::Database.new(File.join(@dir, "pizzas.db"))
    db.execute(%(CREATE TABLE "order" (id TEXT PRIMARY KEY)))
    db.execute(%(INSERT INTO "order" (id) VALUES ('older-1')))
  ensure
    db&.close
  end

  def adapter
    @adapter ||= Hecks::Adapters::Sqlite.new(aggregate: @aggregate, settings: { database: "pizzas.db" }, root: @dir)
  end

  def db = adapter.instance_variable_get(:@db)

  def columns = db.execute(%(PRAGMA table_info("order"))).map { |row| row["name"] }

  def declared_names = adapter.send(:persisted_fields).map { |field| field[:name].to_s }

  before { make_older_table! }

  it "adds a column for every declared attribute the table lacked" do
    expect(columns).to include(*declared_names)
  end

  it "keeps the row written before the attributes, with no value in the new columns", :aggregate_failures do
    row = db.execute(%(SELECT * FROM "order" WHERE id = 'older-1')).first
    expect(row).not_to be_nil
    expect(declared_names.map { |name| row[name] }.compact).to be_empty
  end

  it "adds nothing when the table already has every column" do
    adapter
    again = Hecks::Adapters::Sqlite.new(aggregate: @aggregate, settings: { database: "pizzas.db" }, root: @dir)
    expect(again.instance_variable_get(:@db).execute(%(PRAGMA table_info("order"))).size).to eq(columns.size)
  end
end
