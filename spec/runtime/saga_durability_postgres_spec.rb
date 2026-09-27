require "spec_helper"
require "hecks/ports/persistence/plugins/era"
require_relative "../support/postgres_probe"

# The `saga_durability_spec.rb` proof, run against Postgres. Kept in its own io-gated file like
# the other Postgres-specific specs.
RSpec.describe "durable saga/process-manager state, against Postgres", :io do
  WIRE_BLUEBOOK = File.join(InMemoryDomain::ROOT, "spec/fixtures/settlement.bluebook") unless defined?(WIRE_BLUEBOOK)
  POSTGRES_ERA_ADAPTER = InMemoryDomain::POSTGRES_ERA_ADAPTER
  SAGA_DURABILITY_SPEC_DB = "hecks_saga_durability_spec".freeze

  before(:all) do
    skip "no reachable Postgres — start one to run this spec" unless PostgresProbe.available?

    admin = PG.connect(dbname: "postgres")
    admin.exec("DROP DATABASE IF EXISTS #{SAGA_DURABILITY_SPEC_DB} WITH (FORCE)")
    admin.exec("CREATE DATABASE #{SAGA_DURABILITY_SPEC_DB}")
    admin.close
  end

  after(:all) do
    admin = PG.connect(dbname: "postgres")
    admin.exec("DROP DATABASE IF EXISTS #{SAGA_DURABILITY_SPEC_DB} WITH (FORCE)")
    admin.close
  end

  before do
    scrub = PG.connect(dbname: SAGA_DURABILITY_SPEC_DB)
    scrub.exec("DROP SCHEMA public CASCADE")
    scrub.exec("CREATE SCHEMA public")
    scrub.close
  end

  def boot_wire
    registry = Hecks::Runtime::Registry.new

    Hecks.with_registry(registry) do
      Kernel.load(InMemoryDomain::PERSISTENCE_PORT)
      Kernel.load(InMemoryDomain::EXTRACTION_PORT)
      Kernel.load(InMemoryDomain::MEMORY_ADAPTER)
      Kernel.load(POSTGRES_ERA_ADAPTER)
      Kernel.load(InMemoryDomain::PRISM_ADAPTER)
      Kernel.load(WIRE_BLUEBOOK)
      # Commands declare `role`; without `uses_framework "Governance"` the builder refuses
      # ungoverned roles (refuse_ungoverned_roles!).
      Hecks.hecksagon("Wire") do
        uses_framework "Governance"
        persisted_by "PostgresEra"
      end
      Hecks.hecksagon("Governance") do
        Governance::RoleAssignment.persisted_by("Memory")
        Governance::RoleTransition.persisted_by("Memory")
      end
      Hecks.world("Wire") { persisted_by("PostgresEra") { database(SAGA_DURABILITY_SPEC_DB) } }
    end

    registry.verify!
    registry.rehydrate_sagas!
    Hecks::Runtime::Loader.bind_runtime(Hecks::Runtime::Dispatcher.new(registry))
  end

  def stuck_wire(runtime)
    runtime.dispatch_flat("Wire::Drawer.Open", number: { value: "left" })
    runtime.dispatch_flat("Wire::Drawer.Open", number: { value: "right" })
    runtime.dispatch_flat("Wire::Drawer.Put",  number: { value: "left" }, amount: { cents: 10_000 })
    runtime.dispatch_flat("Wire::Drawer.Shut", number: { value: "right" })
    runtime.dispatch_flat("Wire::Wire.Ask",
                          reference: { value: "wire-1" }, amount: { cents: 2_500 }, source: "left", destination: "right")
    runtime
  end

  it "writes a saga checkpoint through Postgres as the saga advances" do
    runtime = stuck_wire(boot_wire)

    expect(runtime.registry.saga_instances["Carry"]["wire-1"]).to include(state: "returned")
    rows = runtime.registry.saga_persistence("Wire").each_saga.to_a
    expect(rows).to contain_exactly(["Carry", "wire-1", "returned", hash_including(reference: { value: "wire-1" }), []])
  end

  it "REHYDRATES a stuck saga on a fresh boot against the same Postgres database" do
    stuck_wire(boot_wire)

    reopened = boot_wire
    expect(reopened.registry.saga_instances["Carry"]["wire-1"]).to include(
      state: "returned", memory: include(reference: { value: "wire-1" })
    )
  end
end
