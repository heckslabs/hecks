require "spec_helper"
require "tmpdir"

# verify! warns, not refuses, when a process_manager's saga store has no save_saga: dev and
# test legitimately run sagas on Memory (as saga_durability_spec.rb does); a restart loses them.
RSpec.describe "verify! warning for an undurable process_manager" do
  WIRE_BLUEBOOK = File.join(InMemoryDomain::ROOT, "spec/fixtures/settlement.bluebook") unless defined?(WIRE_BLUEBOOK)

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
        attaches "Governance"
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
          attaches "Governance"
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
