require "hecks"
require "tmpdir"
require_relative "../../support/postgres_probe"
require_relative "../../support/scratch_postgres"

# A domain bound to `Postgres` with no `revisions` keeps the table layout (ADR 0182's
# compatibility bar): the same tables and columns the plain adapter has always made, the record
# written to its own table, and no revision machinery. The one table it adds is `hecks_layouts`,
# where the layout is recorded.
RSpec.describe "Postgres without revisions, booted against a database", :io do
  TABLE_LAYOUT_DB = "hecks_postgres_table_layout_spec".freeze

  scratch_postgres TABLE_LAYOUT_DB

  # Every table and column the table layout makes for one aggregate, `Ledger::Acct`.
  TABLE_LAYOUT_COLUMNS = {
    "acct"                  => %w[hecks_version id kind],
    "acct_entries"          => %w[aggregate_id mirrors operation sequence state],
    "events"                => %w[aggregate aggregate_id id name occurred_at payload],
    "hecks_checkpoints"     => %w[aggregate_table compacted_through last_sequence],
    "hecks_dispatch_claims" => %w[claim_key claimed_at],
    "hecks_outbox"          => %w[aggregate attempts claimed_at consumer delivery_id domain enqueued_at error event
                                  event_uid id kind settled_at status],
    "hecks_saga_instances"  => %w[completed_compensations correlation domain memory process_manager state updated_at]
  }.freeze

  def source
    <<~BLUEBOOK
      Hecks.bluebook "Ledger" do
        aggregate "Acct" do
          identified_by :kind

          attribute :kind, Kind

          value_object "Kind" do
            attribute :label, String
          end

          command "Open" do
            goal "Open an account of a kind"
            attribute :kind, Kind
            sets :kind
            emits "Opened"
          end
        end
      end
    BLUEBOOK
  end

  def write_domain(dir, settings: "")
    File.write(File.join(dir, "ledger.bluebook"), source)
    File.write(File.join(dir, "ledger.hecksagon"), %(Hecks.hecksagon "Ledger" do\n  persisted_by "Postgres"\nend\n))
    world = %(Hecks.world "Ledger" do\n  persisted_by("Postgres") do\n    database "#{TABLE_LAYOUT_DB}"\n)
    File.write(File.join(dir, "ledger.world"), "#{world}#{settings}  end\nend\n")
  end

  def boot(settings: "")
    Dir.mktmpdir("table-layout") do |dir|
      write_domain(dir, settings: settings)
      return Hecks.boot(dir, install_driving: false)
    end
  end

  def repository(runtime)
    registry = runtime.registry
    registry.repository("Ledger", registry.bluebook("Ledger").aggregate("Acct"))
  end

  def columns
    db = PG.connect(dbname: TABLE_LAYOUT_DB)
    rows = db.exec("SELECT table_name, column_name FROM information_schema.columns WHERE table_schema = 'public'")
    rows.group_by { |row| row["table_name"] }.transform_values { |cols| cols.map { |row| row["column_name"] }.sort }
  ensure
    db&.close
  end

  it "builds the repository as the table layout" do
    expect(repository(boot).adapter).to be_an_instance_of(Hecks::Adapters::Postgres)
  end

  it "makes exactly the table layout's tables and columns" do
    repository(boot)

    expect(columns.except("hecks_layouts")).to eq(TABLE_LAYOUT_COLUMNS)
  end

  it "adds only the layout record beside them" do
    repository(boot)

    expect(columns.keys - TABLE_LAYOUT_COLUMNS.keys).to eq(["hecks_layouts"])
  end

  it "registers no era gate, so no era is resolved" do
    expect(boot.registry.resolved_eras).not_to have_key("Ledger")
  end

  it "keeps a saved record in its own table" do
    store = repository(boot)
    store.save(Hecks::Runtime::Instance.new(aggregate: store.aggregate, id: "a1", state: { kind: { "label" => "biz" } }))

    expect(store.find("a1").kind.to_h).to eq(label: "biz")
  end

  it "refuses a revision-only setting in the world, naming the word that turns revisions on" do
    expect { repository(boot(settings: "    mint_eras true\n")) }
      .to raise_error(Hecks::Runtime::WiringError,
                      /Ledger binds Postgres without revisions, but its world sets :mint_eras, .*Add `revisions true`/)
  end
end
