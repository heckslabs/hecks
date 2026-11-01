require "hecks"
require "tmpdir"
require "sqlite3"
require_relative "../../support/postgres_probe"

# The data-loss case: a rename whose stored name stops reaching the table the rows are in would
# point the adapter at a new, empty table and the rows would seem gone. The boot refuses by name.
RSpec.describe "the Sqlite stored-name guard" do
  let(:dir) { Dir.mktmpdir("stored-name-guard") }
  let(:path) { File.join(dir, "ledger.db") }
  let(:aggregate) do
    registry = Hecks::Runtime::Registry.new
    Hecks.with_registry(registry) do
      Kernel.load(InMemoryDomain::EXTRACTION_PORT)
      Kernel.load(InMemoryDomain::PRISM_ADAPTER)
      Hecks.bluebook("Ledger") do
        aggregate "Revision" do
          identified_by :tag
          attribute :tag, Tag

          value_object "Tag" do
            attribute :label, String
          end

          command "Record" do
            attribute :tag, Tag
            emits "Recorded"
          end
        end
      end
    end
    registry.bluebook("Ledger").aggregate("Revision")
  end

  after { FileUtils.remove_entry(dir) }

  ENTRY_COLUMNS = "sequence INTEGER PRIMARY KEY AUTOINCREMENT, aggregate_id TEXT, operation TEXT, state TEXT, mirrors TEXT".freeze

  def hold_rows_under(name, rows: 1)
    db = SQLite3::Database.new(path)
    db.execute(%(CREATE TABLE "#{name}" (id TEXT PRIMARY KEY)))
    db.execute(%(CREATE TABLE "#{name}_entries" (#{ENTRY_COLUMNS})))
    insert = %(INSERT INTO "#{name}_entries" (aggregate_id, operation, state) VALUES (?, 'save', '{}'))
    rows.times { |i| db.execute(insert, ["r#{i}"]) }
    db.close
  end

  def tables
    db = SQLite3::Database.new(path)
    db.execute("SELECT name FROM sqlite_master WHERE type = 'table'").flatten
  ensure
    db.close
  end

  def refused
    yield
  rescue Hecks::Runtime::WiringError => e
    e
  end

  def boot = Hecks::Adapters::Sqlite.new(aggregate: aggregate, settings: { database: path })

  it "refuses to create an empty table beside the rows the former name holds" do
    hold_rows_under("commit")
    aggregate.prior_storage_names = ["commit"]
    expect { boot }.to raise_error(Hecks::Runtime::WiringError, /Revision.*"commit".*holds rows.*stored_as/m)
  end

  it "creates no table when it refuses" do
    hold_rows_under("commit")
    aggregate.prior_storage_names = ["commit"]
    refused { boot }
    expect(tables).not_to include("revision")
  end

  it "boots when the world points the aggregate at the table the rows are in" do
    hold_rows_under("commit")
    aggregate.stored_as = "commit"
    aggregate.prior_storage_names = ["commit"]
    expect { boot }.not_to raise_error
  end

  it "boots when the former table is empty" do
    hold_rows_under("commit", rows: 0)
    aggregate.prior_storage_names = ["commit"]
    expect { boot }.not_to raise_error
  end

  it "boots when no former table exists" do
    aggregate.prior_storage_names = ["commit"]
    boot
    expect(tables).to include("revision")
  end

  it "boots when the aggregate has no prior names" do
    hold_rows_under("commit")
    expect { boot }.not_to raise_error
  end
end
