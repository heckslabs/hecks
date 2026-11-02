require "spec_helper"
require "tmpdir"

# A process manager is checkpointed with the records that start it when the hecksagon binds that
# aggregate on its own: the domain stays in Memory, the Wire aggregate (whose Ask starts Carry)
# is bound to SqlitePersistence in a temporary database, and a stuck Carry survives a restart.
RSpec.describe "a saga checkpointed with the aggregate that starts it" do
  SETTLEMENT = File.join(InMemoryDomain::ROOT, "spec/fixtures/settlement.bluebook") unless defined?(SETTLEMENT)
  SQLITE = File.join(InMemoryDomain::ROOT, "lib/hecks/adapters/driven/sqlite.adapter") unless defined?(SQLITE)

  around do |example|
    @dir = Dir.mktmpdir("hecks-saga-anchor-")
    example.run
  ensure
    FileUtils.remove_entry(@dir) if @dir
  end

  def bind(root)
    Hecks.hecksagon("Wire") do
      attaches "Governance"
      persisted_by "Memory"
      Wire::Wire.persisted_by("SqlitePersistence")
    end
    Hecks.hecksagon("Governance") { persisted_by "Memory" }
    Hecks.world("Wire") { persisted_by("SqlitePersistence") { database(File.join(root, "wire.db")) } }
  end

  def declare(root)
    [InMemoryDomain::PERSISTENCE_PORT, InMemoryDomain::EXTRACTION_PORT, InMemoryDomain::MEMORY_ADAPTER, SQLITE,
     InMemoryDomain::PRISM_ADAPTER, SETTLEMENT].each { |file| Kernel.load(file) }
    bind(root)
  end

  def boot
    registry = Hecks::Runtime::Registry.new(root: @dir)
    Hecks.with_registry(registry) { declare(@dir) }
    registry.verify!
    registry.rehydrate_sagas!
    Hecks::Runtime::Loader.bind_runtime(Hecks::Runtime::Dispatcher.new(registry))
  end

  def stuck(runtime)
    runtime.dispatch_flat("Wire::Drawer.Open", number: { value: "left" })
    runtime.dispatch_flat("Wire::Drawer.Open", number: { value: "right" })
    runtime.dispatch_flat("Wire::Drawer.Put",  number: { value: "left" }, amount: { cents: 10_000 })
    runtime.dispatch_flat("Wire::Drawer.Shut", number: { value: "right" })
    runtime.dispatch_flat("Wire::Wire.Ask", reference: { value: "wire-1" }, amount: { cents: 2_500 },
                                            source: "left", destination: "right")
  end

  it "holds the saga in the starting aggregate's store while the domain's own has none", :aggregate_failures do
    registry = boot.registry
    expect(registry.saga_persistence("Wire")).to be(Hecks::Ports::Persistence::NULL_SAGA_STORE)
    expect(registry.saga_persistence("Wire", "Carry")).to respond_to(:save_saga)
  end

  it "rehydrates a stuck saga from that store on a fresh boot" do
    stuck(boot)
    expect(boot.registry.saga_instances["Carry"]["wire-1"]).to include(state: "returned")
  end

  it "warns of no lost saga when every process manager has a store" do
    expect { boot.registry.verify! }.not_to output(/LOST on restart/).to_stderr
  end
end
