require "hecks"
require "tmpdir"
require_relative "../../support/postgres_probe"
require_relative "../../support/scratch_postgres"
require_relative "../../support/fenced_owner"
require_relative "../../support/first_era_hold"

# A domain bound to `Postgres` whose hecksagon says `revisions true` boots the revision layout end
# to end (ADR 0182): the era gate runs, the boot marks reach the adapter, and the settings its world
# declares under `persisted_by("Postgres")` reach both the gate and the adapter.
RSpec.describe "Postgres with revisions true, booted against a database", :io do
  include FirstEraHold

  REVISIONS_BOOT_DB = "hecks_postgres_revisions_boot_spec".freeze

  scratch_postgres REVISIONS_BOOT_DB, fenced: true

  def url = FencedOwner.url(REVISIONS_BOOT_DB)

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

  # Writes the domain's files: the bluebook, a hecksagon on Postgres with revisions, and a world
  # whose `persisted_by("Postgres")` block carries `settings` under the database.
  def write_domain(dir, text, settings: "")
    File.write(File.join(dir, "ledger.bluebook"), text)
    File.write(File.join(dir, "ledger.hecksagon"),
               %(Hecks.hecksagon "Ledger" do\n  persisted_by "Postgres"\n  revisions true\nend\n))
    File.write(File.join(dir, "ledger.world"),
               %(Hecks.world "Ledger" do\n  persisted_by("Postgres") do\n    database "#{url}"\n#{settings}  end\nend\n))
  end

  # Holds era 1 of the domain's source, in `schema` when given, then boots it.
  def boot(settings: "", schema: nil)
    hold_first_era!(url: url, domain: "Ledger", source: source, schema: schema)
    Dir.mktmpdir("revisions-boot") do |dir|
      write_domain(dir, source, settings: settings)
      return Hecks.boot(dir, install_driving: false)
    end
  end

  def repository(runtime)
    registry = runtime.registry
    registry.repository("Ledger", registry.bluebook("Ledger").aggregate("Acct"))
  end

  it "runs the era gate, which resolves the held era" do
    expect(boot.registry.resolved_eras["Ledger"]).to eq(1)
  end

  it "reads the world's schema under Postgres, so the era held in that schema resolves" do
    runtime = boot(settings: "    schema \"ledger_tenant\"\n", schema: "ledger_tenant")

    expect(runtime.registry.resolved_eras["Ledger"]).to eq(1)
  end

  it "builds the repository as the revision layout" do
    expect(repository(boot).adapter).to be_a(Hecks::Adapters::PostgresEra)
  end

  it "hands the adapter the boot marks the era gate left" do
    expect(repository(boot).adapter.instance_variable_get(:@settings)).to include(domain: "Ledger", era: 1)
  end

  it "reads the world's settings under Postgres in the era gate, so a mints_era naming no command refuses" do
    expect { boot(settings: "    mints_era \"Acct.Close\"\n") }
      .to raise_error(Hecks::Runtime::WiringError, /the world's mints_era names Acct.Close, but Ledger declares no such/)
  end

  it "reads the world's settings under Postgres in the adapter, so mints_era reaches it" do
    adapter = repository(boot(settings: "    mints_era \"Acct.Open\"\n")).adapter

    expect(adapter.mints_era_declared?("Acct", "Open")).to be(true)
  end
end
