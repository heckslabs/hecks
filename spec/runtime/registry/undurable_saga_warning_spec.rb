require "spec_helper"
require "tmpdir"

# §8 — `verify!` warns, loudly and at boot, when a domain declares a
# `process_manager` but its resolved `saga_persistence` has no
# `save_saga` (NULL_SAGA_STORE). Sagas still run correctly in-process
# on that store; what's missing is durability across a restart — no
# checkpoint, no rehydration, no compensation replay if the process
# dies mid-saga. Silent until then, which is exactly the shape ADR
# 0025 refused for an unchecked `role`. Here the same gap gets a
# WARNING rather than a refusal, because — unlike an ungoverned role —
# running a saga on a non-durable store is something an author chooses
# on purpose in dev/test (`saga_durability_spec.rb`'s own saga_mutex
# spec boots the identical Wire fixture on Memory for exactly that
# reason), so refusing the boot outright would make that legitimate
# choice impossible.
RSpec.describe "verify! warning for an undurable process_manager" do
  WIRE_BLUEBOOK = File.join(InMemoryDomain::ROOT, "spec/fixtures/settlement.bluebook")

  def load_wire(registry)
    Hecks.with_registry(registry) do
      Kernel.load(InMemoryDomain::PERSISTENCE_PORT)
      Kernel.load(InMemoryDomain::EXTRACTION_PORT)
      Kernel.load(InMemoryDomain::MEMORY_ADAPTER)
      Kernel.load(InMemoryDomain::PRISM_ADAPTER)
      Kernel.load(WIRE_BLUEBOOK)
    end
  end

  it "warns when a process_manager resolves to the no-op saga store" do
    registry = Hecks::Runtime::Registry.new
    load_wire(registry)
    Hecks.with_registry(registry) do
      Hecks.hecksagon("Wire") do
        uses_framework "Governance"
        persisted_by "Memory"
      end
      Hecks.hecksagon("Governance") do
        Governance::RoleAssignment.persisted_by("Memory")
        Governance::RoleTransition.persisted_by("Memory")
      end
    end

    expect { registry.verify! }.to output(
      /Wire declares process_manager\(s\) Carry but its resolved persistence adapter has no save_saga/
    ).to_stderr
  end

  it "does not warn once the domain is bound to an adapter that implements save_saga" do
    registry = Hecks::Runtime::Registry.new
    Hecks.with_registry(registry) { Kernel.load(File.join(InMemoryDomain::ROOT, "lib/hecks/adapters/driven/sqlite.adapter")) }
    load_wire(registry)
    Dir.mktmpdir do |dir|
      Hecks.with_registry(registry) do
        Hecks.hecksagon("Wire") do
          uses_framework "Governance"
          persisted_by "SqlitePersistence"
        end
        Hecks.hecksagon("Governance") do
          Governance::RoleAssignment.persisted_by("Memory")
          Governance::RoleTransition.persisted_by("Memory")
        end
        Hecks.world("Wire") { persisted_by("SqlitePersistence") { database(File.join(dir, "wire.db")) } }
      end

      expect { registry.verify! }.not_to output(/process_manager/).to_stderr
    end
  end

  it "does not warn for a domain with no process_manager at all" do
    registry = Hecks::Runtime::Registry.new
    Hecks.with_registry(registry) do
      Kernel.load(InMemoryDomain::PERSISTENCE_PORT)
      Kernel.load(InMemoryDomain::EXTRACTION_PORT)
      Kernel.load(InMemoryDomain::MEMORY_ADAPTER)
      Kernel.load(InMemoryDomain::PRISM_ADAPTER)
      Hecks.bluebook("Plain") do
        vision "Nothing to correlate."
        supporting
        aggregate("Thing") { identified_by :id }
      end
      Hecks.hecksagon("Plain") { Plain::Thing.persisted_by("Memory") }
    end

    expect { registry.verify! }.not_to output(/process_manager/).to_stderr
  end
end
