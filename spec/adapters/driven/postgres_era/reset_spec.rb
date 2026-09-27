require "hecks"
require "hecks/ports/persistence/plugins/era"
require "tempfile"
require_relative "../../../support/postgres_probe"

# `PostgresEra#reset!` raises rather than silently deleting nothing when the journal's
# force-RLS policies admit no DELETE. Needs a non-superuser owner: superusers bypass RLS.
RSpec.describe "PostgresEra#reset! against a lineage-provisioned journal", :io do
  RESET_DB = "hecks_reset_spec".freeze
  RESET_OWNER = "hecks_reset_spec_owner".freeze

  def owner_url = "postgres://#{RESET_OWNER}@localhost/#{RESET_DB}"

  RESET_SPEC_SOURCE = <<~BLUEBOOK.freeze
    Hecks.bluebook "Ledger" do
      aggregate "Acct" do
        identified_by :kind

        attribute :cost, Money
        attribute :kind, Kind

        value_object "Money" do
          attribute :cents, Integer
        end

        value_object "Kind" do
          attribute :label, String
        end
      end
    end
  BLUEBOOK

  before(:all) do
    skip "no reachable Postgres — start one to run this spec" unless PostgresProbe.available?

    admin = PG.connect(dbname: "postgres")
    admin.exec("DROP DATABASE IF EXISTS #{RESET_DB} WITH (FORCE)")
    admin.exec("CREATE DATABASE #{RESET_DB}")
    admin.exec("DROP ROLE IF EXISTS #{RESET_OWNER}")
    # No superuser or BYPASSRLS: either would make FORCE ROW LEVEL SECURITY a no-op for the role.
    admin.exec("CREATE ROLE #{RESET_OWNER} LOGIN")
    admin.close
    grant = PG.connect(dbname: RESET_DB)
    grant.exec("GRANT CONNECT ON DATABASE #{RESET_DB} TO #{RESET_OWNER}")
    grant.close
  end

  after(:all) do
    admin = PG.connect(dbname: "postgres")
    admin.exec("DROP DATABASE IF EXISTS #{RESET_DB} WITH (FORCE)")
    admin.close
  end

  before do
    scrub = PG.connect(dbname: RESET_DB)
    scrub.exec("DROP SCHEMA public CASCADE")
    scrub.exec("CREATE SCHEMA public")
    scrub.exec("GRANT USAGE, CREATE ON SCHEMA public TO #{RESET_OWNER}")
    scrub.close
  end

  def load_registry(source)
    registry = Hecks::Runtime::Registry.new
    loading = Hecks::Ports::Loading.bootstrap
    file = Tempfile.new(["reset-", ".bluebook"])
    file.write(source)
    file.flush
    Hecks.with_registry(registry) do
      loading.load_library
      Kernel.eval(source, TOPLEVEL_BINDING, file.path, 1)
    end
    registry
  ensure
    file&.close!
  end

  def check!
    registry = load_registry(RESET_SPEC_SOURCE)
    bluebook = registry.bluebooks.values.first
    Hecks::Adapters::PostgresEra::LineageManager.check!(
      registry: registry, bluebook: bluebook, current_text: RESET_SPEC_SOURCE, settings: { database: owner_url }
    )
    registry
  end

  def adapter_for(registry)
    aggregate = registry.bluebooks.values.first.aggregate("Acct")
    Hecks::Adapters::PostgresEra.new(aggregate: aggregate, settings: { database: owner_url, domain: "Ledger" })
  end

  def write_a_record(adapter, registry, id: "a1")
    instance = Hecks::Runtime::Instance.new(
      aggregate: registry.bluebooks.values.first.aggregate("Acct"), id: id,
      state: { cost: { "cents" => 100 }, kind: { "label" => "biz" } }
    )
    adapter.save(instance)
  end

  it "raises a WiringError instead of silently deleting nothing, when RLS admits no DELETE" do
    registry = check!
    adapter = adapter_for(registry)
    write_a_record(adapter, registry)
    expect(adapter.find("a1")).not_to be_nil

    expect { adapter.reset! }.to raise_error(Hecks::Runtime::WiringError, /FORCE ROW LEVEL SECURITY|DELETE policy/)

    # A silent no-op would leave the record behind; it must still be there.
    expect(adapter.find("a1")).not_to be_nil
  end

  it "does not raise, and genuinely clears the journal, for a role that bypasses RLS" do
    registry = check!
    # The ambient connection is the local default user, commonly a superuser, which bypasses RLS.
    aggregate = registry.bluebooks.values.first.aggregate("Acct")
    ambient_adapter = Hecks::Adapters::PostgresEra.new(aggregate: aggregate, settings: { database: RESET_DB, domain: "Ledger" })
    write_a_record(ambient_adapter, registry, id: "a2")
    expect(ambient_adapter.entries).not_to be_empty

    # `entries` reads the journal directly, unlike `find`, which reads a derived head.
    expect { ambient_adapter.reset! }.not_to raise_error
    expect(ambient_adapter.entries).to be_empty
  end
end
