require "spec_helper"
require "tmpdir"
require_relative "../../support/memory_ports"

# verify! refuses a process manager whose checkpoints no store keeps when it dispatches to an
# aggregate a store keeps across a restart (ADR 0170). Wire's Carry dispatches to Drawer and Wire.
RSpec.describe "verify! refusal for a saga less durable than the aggregates it moves" do
  WIRE_FIXTURE = File.join(InMemoryDomain::ROOT, "spec/fixtures/settlement.bluebook") unless defined?(WIRE_FIXTURE)
  FORGETFUL_CARRY = /Carry dispatches to Wire, which SqlitePersistence keeps/ unless defined?(FORGETFUL_CARRY)
  SQLITE_ADAPTER = File.join(InMemoryDomain::ROOT, "lib/hecks/adapters/driven/sqlite.adapter") unless defined?(SQLITE_ADAPTER)

  def load_wire(registry)
    Hecks.with_registry(registry) do
      MemoryPorts.load!
      Kernel.load(SQLITE_ADAPTER)
      Kernel.load(WIRE_FIXTURE)
    end
  end

  def bind_governance
    Hecks.hecksagon("Governance") do
      Governance::RoleAssignment.persisted_by("Memory")
      Governance::RoleTransition.persisted_by("Memory")
    end
  end

  def wire_world(dir)
    Hecks.world("Wire") { persisted_by("SqlitePersistence") { database(File.join(dir, "wire.db")) } }
  end

  # Wire's root on `root`; Drawer, the domain's first aggregate and so its saga store, on `drawer`.
  def wire_registry(dir, root:, drawer: nil)
    registry = Hecks::Runtime::Registry.new
    load_wire(registry)
    Hecks.with_registry(registry) do
      bind_wire(root, drawer)
      bind_governance
      wire_world(dir)
    end
    registry
  end

  def bind_wire(root, drawer)
    Hecks.hecksagon("Wire") do
      attaches "Governance"
      persisted_by root
      Wire::Drawer.persisted_by(drawer) if drawer
    end
  end

  # Plain has no hecksagon; its world alone keeps its records in Sqlite.
  def plain_world(dir)
    Hecks.world("Plain") do
      default_adapter "SqlitePersistence"
      persisted_by("SqlitePersistence") { database(File.join(dir, "plain.db")) }
    end
  end

  def plain_registry(dir)
    registry = Hecks::Runtime::Registry.new
    Hecks.with_registry(registry) do
      MemoryPorts.load!
      Kernel.load(SQLITE_ADAPTER)
      Hecks.bluebook("Plain") { aggregate("Thing") { identified_by :id } }
      plain_world(dir)
    end
    registry
  end

  def in_tmpdir(&) = Dir.mktmpdir(&)

  it "refuses when the saga store is Memory and a dispatched aggregate is kept by Sqlite" do
    in_tmpdir do |dir|
      registry = wire_registry(dir, root: "SqlitePersistence", drawer: "Memory")
      expect { registry.verify! }.to raise_error(Hecks::Runtime::WiringError, FORGETFUL_CARRY)
    end
  end

  it "leaves an all-Memory domain booting" do
    in_tmpdir do |dir|
      expect { wire_registry(dir, root: "Memory").verify! }.not_to raise_error
    end
  end

  it "leaves a domain whose sagas are kept where its records are booting" do
    in_tmpdir do |dir|
      expect { wire_registry(dir, root: "SqlitePersistence").verify! }.not_to raise_error
    end
  end

  it "keeps a domain's sagas where its world keeps its records when it has no hecksagon" do
    in_tmpdir do |dir|
      expect(plain_registry(dir).saga_persistence("Plain")).to respond_to(:save_saga)
    end
  end
end
