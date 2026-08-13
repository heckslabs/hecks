require "spec_helper"
require_relative "../support/postgres_probe"

# The SAME end-to-end proof `saga_durability_spec.rb` runs against
# SqlitePersistence, run again against Postgres — the production-urgent
# adapter this whole arc started from (Banking's own real `Settlement`/
# `ExternalSettlement`, deployed on Lambda, Phase 1's own subject).
# Kept as a SEPARATE, io:true-gated file rather than folded into the
# unconditional spec, matching every other Postgres-vs-everything-else
# split in this suite (postgres_spec.rb itself, banking_matrix_spec.rb).
RSpec.describe "durable saga/process-manager state, against Postgres",
               io: true,
               skip: (PostgresProbe::AVAILABLE ? false : "no reachable Postgres — start one to run this spec") do
  WIRE_BLUEBOOK = File.join(InMemoryDomain::ROOT, "spec/fixtures/settlement.bluebook")
  POSTGRES_ADAPTER = InMemoryDomain::POSTGRES_ADAPTER
  SPEC_DB = "hecksagain_saga_durability_spec".freeze

  before(:all) do
    admin = PG.connect(dbname: "postgres")
    admin.exec("DROP DATABASE IF EXISTS #{SPEC_DB} WITH (FORCE)")
    admin.exec("CREATE DATABASE #{SPEC_DB}")
    admin.close
  end

  after(:all) do
    admin = PG.connect(dbname: "postgres")
    admin.exec("DROP DATABASE IF EXISTS #{SPEC_DB} WITH (FORCE)")
    admin.close
  end

  before do
    scrub = PG.connect(dbname: SPEC_DB)
    scrub.exec("DROP SCHEMA public CASCADE")
    scrub.exec("CREATE SCHEMA public")
    scrub.close
  end

  def boot_wire
    registry = Hecksagain::Runtime::Registry.new

    Hecksagain.with_registry(registry) do
      Kernel.load(InMemoryDomain::PERSISTENCE_PORT)
      Kernel.load(InMemoryDomain::EXTRACTION_PORT)
      Kernel.load(InMemoryDomain::MEMORY_ADAPTER)
      Kernel.load(POSTGRES_ADAPTER)
      Kernel.load(InMemoryDomain::PRISM_ADAPTER)
      Kernel.load(WIRE_BLUEBOOK)
      Hecks.hecksagon("Wire") { persisted_by "Postgres" }
      Hecks.world("Wire") { persisted_by("Postgres") { database(SPEC_DB) } }
    end

    registry.verify!
    registry.rehydrate_sagas!
    Hecksagain::Runtime::Loader.bind_runtime(Hecksagain::Runtime::Dispatcher.new(registry))
  end

  def stuck_wire(runtime)
    runtime.dispatch("Wire::Drawer.Open", number: { value: "left" })
    runtime.dispatch("Wire::Drawer.Open", number: { value: "right" })
    runtime.dispatch("Wire::Drawer.Put",  number: { value: "left" }, amount: { cents: 10_000 })
    runtime.dispatch("Wire::Drawer.Shut", number: { value: "right" })
    runtime.dispatch("Wire::Wire.Ask",
                     reference: { value: "wire-1" }, amount: { cents: 2_500 }, source: "left", destination: "right")
    runtime
  end

  it "writes a saga checkpoint through Postgres as the saga advances" do
    runtime = stuck_wire(boot_wire)

    expect(runtime.registry.saga_instances["Carry"]["wire-1"]).to include(state: "returned")
    rows = runtime.registry.saga_persistence("Wire").each_saga.to_a
    expect(rows).to contain_exactly(["Carry", "wire-1", "returned", hash_including(reference: { value: "wire-1" })])
  end

  it "REHYDRATES a stuck saga on a fresh boot against the same Postgres database" do
    stuck_wire(boot_wire)

    reopened = boot_wire
    expect(reopened.registry.saga_instances["Carry"]["wire-1"]).to include(
      state: "returned", memory: include(reference: { value: "wire-1" })
    )
  end
end
