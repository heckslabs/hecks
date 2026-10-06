require "hecks"
require "hecks/ports/persistence/plugins/era"
require_relative "../../../support/postgres_probe"
require_relative "../../../support/era_registry_loading"

# `PostgresEra#reset!` raises rather than silently deleting nothing when the journal's
# force-RLS policies admit no DELETE. Needs a non-superuser owner: superusers bypass RLS.
RSpec.describe "PostgresEra#reset! against a lineage-provisioned journal", :io do
  include EraRegistryLoading

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

  let(:registry) { check! }
  let(:adapter) { adapter_for(registry) }

  context "when RLS admits no DELETE" do
    before { write_a_record(adapter, registry) }

    it "raises a WiringError instead of silently deleting nothing" do
      expect { adapter.reset! }.to raise_error(Hecks::Runtime::WiringError, /FORCE ROW LEVEL SECURITY|DELETE policy/)
    end

    # A silent no-op would leave the record behind; it must still be there.
    it "leaves the record in place", :aggregate_failures do
      expect(adapter.find("a1")).not_to be_nil
      expect { adapter.reset! }.to raise_error(Hecks::Runtime::WiringError)
      expect(adapter.find("a1")).not_to be_nil
    end
  end

  context "with a role that bypasses RLS" do
    # The ambient connection is the local default user, commonly a superuser, which bypasses RLS.
    let(:ambient_adapter) do
      aggregate = registry.bluebooks.values.first.aggregate("Acct")
      Hecks::Adapters::PostgresEra.new(aggregate: aggregate, settings: { database: RESET_DB, domain: "Ledger" })
    end

    before { write_a_record(ambient_adapter, registry, id: "a2") }

    it "does not raise" do
      expect { ambient_adapter.reset! }.not_to raise_error
    end

    # `entries` reads the journal directly, unlike `find`, which reads a derived head.
    it "genuinely clears the journal", :aggregate_failures do
      expect(ambient_adapter.entries).not_to be_empty
      ambient_adapter.reset!
      expect(ambient_adapter.entries).to be_empty
    end
  end
end
