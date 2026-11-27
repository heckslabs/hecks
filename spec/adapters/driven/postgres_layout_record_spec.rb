require "hecks"
require "tmpdir"
require_relative "../../support/postgres_probe"
require_relative "../../support/scratch_postgres"
require_relative "../../support/fenced_owner"
require_relative "../../support/first_era_hold"

# The layout a Postgres database keeps a domain in is recorded on the first boot that writes it,
# and a later boot whose hecksagon chose the other layout is refused, naming both (ADR 0182).
RSpec.describe "the Postgres layout record", :io do
  include FirstEraHold

  LAYOUT_RECORD_DB = "hecks_postgres_layout_record_spec".freeze

  scratch_postgres LAYOUT_RECORD_DB, fenced: true

  def url = FencedOwner.url(LAYOUT_RECORD_DB)

  def source
    <<~BLUEBOOK
      Hecks.bluebook "Ledger" do
        aggregate "Acct" do
          identified_by :kind

          attribute :kind, Kind

          value_object "Kind" do
            attribute :label, String
          end
        end
      end
    BLUEBOOK
  end

  def write_domain(dir, revisions)
    File.write(File.join(dir, "ledger.bluebook"), source)
    File.write(File.join(dir, "ledger.hecksagon"),
               %(Hecks.hecksagon "Ledger" do\n  persisted_by "Postgres"\n#{"  revisions true\n" if revisions}end\n))
    File.write(File.join(dir, "ledger.world"),
               %(Hecks.world "Ledger" do\n  persisted_by("Postgres") do\n    database "#{url}"\n  end\nend\n))
  end

  # Boots the domain in the table layout, or with `revisions true` in the revision layout.
  def boot(revisions: false)
    Dir.mktmpdir("layout-record") do |dir|
      write_domain(dir, revisions)
      runtime = Hecks.boot(dir, install_driving: false)
      registry = runtime.registry
      return registry.repository("Ledger", registry.bluebook("Ledger").aggregate("Acct"))
    end
  end

  def hold_era! = hold_first_era!(url: url, domain: "Ledger", source: source)

  def recorded
    db = PG.connect(url)
    db.exec("SELECT layout FROM hecks_layouts WHERE domain = 'Ledger'").first&.fetch("layout")
  ensure
    db&.close
  end

  def drop_record!
    db = PG.connect(url)
    db.exec("DROP TABLE hecks_layouts")
  ensure
    db&.close
  end

  it "records the table layout on the first table-layout boot" do
    boot

    expect(recorded).to eq("table")
  end

  it "records the revision layout when the first era is held" do
    hold_era!

    expect(recorded).to eq("revisions")
  end

  it "boots the same layout again" do
    boot

    expect { boot }.not_to raise_error
  end

  it "refuses a revision-layout boot over a database recorded in the table layout, naming both" do
    boot

    expect { boot(revisions: true) }
      .to raise_error(Hecks::Runtime::WiringError,
                      /cannot boot Ledger in Postgres's revisions layout: its database holds Ledger in the table layout/)
  end

  it "refuses to hold an era over a database recorded in the table layout" do
    boot

    expect { hold_era! }.to raise_error(Hecks::Runtime::WiringError, /holds Ledger in the table layout/)
  end

  it "refuses a table-layout boot over a database recorded in the revision layout, naming both" do
    hold_era!

    expect { boot }
      .to raise_error(Hecks::Runtime::WiringError,
                      /cannot boot Ledger in Postgres's table layout: its database holds Ledger in the revisions layout/)
  end

  it "refuses a table-layout boot over held eras no record names, read from the eras themselves" do
    hold_era!
    drop_record!

    expect { boot }.to raise_error(Hecks::Runtime::WiringError, /holds Ledger in the revisions layout/)
  end

  it "refuses a revision-layout boot over an entry log no record names, read from the log itself" do
    boot
    drop_record!

    expect { boot(revisions: true) }.to raise_error(Hecks::Runtime::WiringError, /holds Ledger in the table layout/)
  end

  it "tells a refused boot how to keep its data" do
    hold_era!

    expect { boot }.to raise_error(Hecks::Runtime::WiringError, /To keep the data, keep `revisions true` in its hecksagon/)
  end
end
