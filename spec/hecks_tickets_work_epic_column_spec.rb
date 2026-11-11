require "spec_helper"
require "tmpdir"

# ADR 0204 gives Work one optional attribute. A Work table made before it has no `epic` column; the
# SQLite adapter adds it on boot and the old row reads with no epic.
RSpec.describe "a Tickets Work table from before epics" do
  around do |example|
    @dir = Dir.mktmpdir("hecks-work-epic-")
    example.run
  ensure
    FileUtils.remove_entry(@dir) if @dir
  end

  let(:aggregate) { boot_hecks_in_memory.registry.bluebook("Tickets").aggregate("Work") }

  def open_adapter
    Hecks::Adapters::Sqlite.new(aggregate: aggregate, settings: { database: "work.db", domain: "Tickets" }, root: @dir)
  end

  def db(adapter) = adapter.instance_variable_get(:@db)

  def save_old_row
    adapter = open_adapter
    old = Hecks::Runtime::Instance.new(aggregate: aggregate, id: "old-1")
    old[:work] = Hecks::Runtime::Value.for(aggregate, :work, { value: "old-1" })
    adapter.save(old)
    ["DROP INDEX idx_work_epic", "ALTER TABLE work DROP COLUMN epic"].each { |sql| db(adapter).execute(sql) }
  end

  it "gets the epic column on boot and still reads the old row", :aggregate_failures do
    save_old_row
    reopened = open_adapter

    expect(db(reopened).execute("PRAGMA table_info(work)").map { |row| row["name"] }).to include("epic")
    expect(reopened.find("old-1")&.id).to eq("old-1")
  end
end
