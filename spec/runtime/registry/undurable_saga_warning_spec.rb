require "spec_helper"
require "tmpdir"
require_relative "../../support/memory_ports"

# verify! warns, not refuses, when a process_manager's saga store has no save_saga while its
# domain keeps records elsewhere. A domain wholly in Memory, bound or by default, chose to keep
# nothing (as saga_durability_spec.rb does), so it stays silent.
RSpec.describe "verify! warning for an undurable process_manager" do
  WIRE_BLUEBOOK = File.join(InMemoryDomain::ROOT, "spec/fixtures/settlement.bluebook") unless defined?(WIRE_BLUEBOOK)

  UNDURABLE_SAGA_WARNING = /Wire declares process_manager\(s\) Carry but its resolved persistence adapter has no save_saga/

  def load_wire(registry)
    Hecks.with_registry(registry) do
      MemoryPorts.load!
      Kernel.load(WIRE_BLUEBOOK)
    end
  end

  def bind_governance
    Hecks.hecksagon("Governance") do
      Governance::RoleAssignment.persisted_by("Memory")
      Governance::RoleTransition.persisted_by("Memory")
    end
  end

  # Wire persisted by the named adapter, with Governance on Memory.
  def bind_wire(adapter)
    Hecks.hecksagon("Wire") do
      attaches "Governance"
      persisted_by adapter
    end
    bind_governance
  end

  def memory_wire_registry
    registry = Hecks::Runtime::Registry.new
    load_wire(registry)
    Hecks.with_registry(registry) { bind_wire("Memory") }
    registry
  end

  def sqlite_wire_registry(dir)
    registry = Hecks::Runtime::Registry.new
    Hecks.with_registry(registry) { Kernel.load(File.join(InMemoryDomain::ROOT, "lib/hecks/adapters/driven/sqlite.adapter")) }
    load_wire(registry)
    Hecks.with_registry(registry) do
      bind_wire("SqlitePersistence")
      Hecks.world("Wire") { persisted_by("SqlitePersistence") { database(File.join(dir, "wire.db")) } }
    end
    registry
  end

  def plain_bluebook
    Hecks.bluebook("Plain") do
      vision "Nothing to correlate."
      supporting
      aggregate("Thing") { identified_by :id }
    end
  end

  def plain_registry
    registry = Hecks::Runtime::Registry.new
    Hecks.with_registry(registry) do
      MemoryPorts.load!
      plain_bluebook
      Hecks.hecksagon("Plain") { Plain::Thing.persisted_by("Memory") }
    end
    registry
  end

  it "stays silent when the whole domain is in Memory" do
    expect { memory_wire_registry.verify! }.not_to output(/process_manager/).to_stderr
  end

  it "warns when records are kept but a process_manager resolves to the no-op saga store" do
    registry = memory_wire_registry
    allow(registry).to receive(:memory_only?).and_return(false)

    expect { registry.verify! }.to output(UNDURABLE_SAGA_WARNING).to_stderr
  end

  it "does not warn once the domain is bound to an adapter that implements save_saga" do
    Dir.mktmpdir do |dir|
      expect { sqlite_wire_registry(dir).verify! }.not_to output(/process_manager/).to_stderr
    end
  end

  it "does not warn for a domain with no process_manager at all" do
    expect { plain_registry.verify! }.not_to output(/process_manager/).to_stderr
  end
end
