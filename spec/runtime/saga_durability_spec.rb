require "spec_helper"
require "tmpdir"

# A stuck process manager survives a restart through a real adapter (SqlitePersistence).
#
# The happy path cascades within one dispatch, so only the `on :refused` leg leaves a
# stuck instance: shutting the destination drawer sends Carry to "returned", a dead end.
RSpec.describe "durable saga/process-manager state" do
  WIRE_BLUEBOOK = File.join(InMemoryDomain::ROOT, "spec/fixtures/settlement.bluebook") unless defined?(WIRE_BLUEBOOK)
  SQLITE_ADAPTER = File.join(InMemoryDomain::ROOT, "lib/hecks/adapters/driven/sqlite.adapter") unless defined?(SQLITE_ADAPTER)

  around do |example|
    @dir = Dir.mktmpdir("hecks-saga-durability-")
    example.run
  ensure
    FileUtils.remove_entry(@dir) if @dir
  end

  def boot_wire(root: @dir)
    registry = Hecks::Runtime::Registry.new(root: root)

    Hecks.with_registry(registry) do
      Kernel.load(InMemoryDomain::PERSISTENCE_PORT)
      Kernel.load(InMemoryDomain::EXTRACTION_PORT)
      Kernel.load(InMemoryDomain::MEMORY_ADAPTER)
      Kernel.load(SQLITE_ADAPTER)
      Kernel.load(InMemoryDomain::PRISM_ADAPTER)
      Kernel.load(WIRE_BLUEBOOK)
      Hecks.hecksagon("Wire") do
        attaches "Governance"
        persisted_by "SqlitePersistence"
      end
      Hecks.hecksagon("Governance") do
        Governance::RoleAssignment.persisted_by("Memory")
        Governance::RoleTransition.persisted_by("Memory")
      end
      Hecks.world("Wire") { persisted_by("SqlitePersistence") { database(File.join(root, "wire.db")) } }
    end

    registry.verify!
    # Mirrors Loader.boot (verify!, rehydrate_sagas!, dispatcher); fixtures are loaded
    # with Kernel.load, not from a bluebook directory, so Loader.boot itself can't be used.
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

  it "writes a saga checkpoint through the real adapter as the saga advances, not just in-memory" do
    runtime = stuck_wire(boot_wire)

    expect(runtime.registry.saga_instances["Carry"]["wire-1"]).to include(state: "returned")

    adapter = runtime.registry.saga_persistence("Wire")
    rows = adapter.each_saga.to_a
    expect(rows).to contain_exactly(["Carry", "wire-1", "returned", hash_including(reference: { value: "wire-1" }), []])
  end

  it "deletes the checkpoint once a saga genuinely ends (the happy path, ends_on)" do
    runtime = boot_wire
    runtime.dispatch_flat("Wire::Drawer.Open", number: { value: "left" })
    runtime.dispatch_flat("Wire::Drawer.Open", number: { value: "right" })
    runtime.dispatch_flat("Wire::Drawer.Put",  number: { value: "left" }, amount: { cents: 10_000 })
    runtime.dispatch_flat("Wire::Wire.Ask",
                          reference: { value: "wire-1" }, amount: { cents: 2_500 }, source: "left", destination: "right")

    expect(runtime.registry.saga_instances["Carry"]).to be_empty
    expect(runtime.registry.saga_persistence("Wire").each_saga.to_a).to eq([])
  end

  it "REHYDRATES a stuck saga on a fresh boot against the same store — the actual regression" do
    stuck_wire(boot_wire)

    # A fresh Registry shares only the sqlite file, as after a process restart.
    reopened = boot_wire

    expect(reopened.registry.saga_instances["Carry"]["wire-1"]).to include(
      state: "returned", memory: include(reference: { value: "wire-1" })
    )
  end

  it "rehydration is a real no-op for a domain with nothing stuck" do
    runtime = boot_wire
    runtime.dispatch_flat("Wire::Drawer.Open", number: { value: "left" })

    reopened = boot_wire
    expect(reopened.registry.saga_instances["Carry"]).to be_empty
  end

  describe "the saga_mutex (§7)" do
    # Boots a Memory-backed registry, not boot_wire: the mutex claim needs no real I/O.
    # One example because the race needs the shared runtime.
    # rubocop:disable-next RSpec/ExampleLength
    it "keeps two threads racing begin_saga on the SAME correlation from double-booking or losing a checkpoint" do
      registry = Hecks::Runtime::Registry.new
      Hecks.with_registry(registry) do
        Kernel.load(InMemoryDomain::PERSISTENCE_PORT)
        Kernel.load(InMemoryDomain::EXTRACTION_PORT)
        Kernel.load(InMemoryDomain::MEMORY_ADAPTER)
        Kernel.load(InMemoryDomain::PRISM_ADAPTER)
        Kernel.load(WIRE_BLUEBOOK)
        Hecks.hecksagon("Wire") do
          attaches "Governance"
          persisted_by "Memory"
        end
        Hecks.hecksagon("Governance") do
          Governance::RoleAssignment.persisted_by("Memory")
          Governance::RoleTransition.persisted_by("Memory")
        end
      end
      registry.verify!
      runtime = Hecks::Runtime::Loader.bind_runtime(Hecks::Runtime::Dispatcher.new(registry))

      runtime.dispatch_flat("Wire::Drawer.Open", number: { value: "left" })
      runtime.dispatch_flat("Wire::Drawer.Open", number: { value: "right" })
      runtime.dispatch_flat("Wire::Drawer.Put",  number: { value: "left" }, amount: { cents: 10_000 })

      # Every thread collides on one correlation: exactly one may begin the instance, the
      # rest must skip without overwriting it. Without the mutex, begin_saga's key? check races.
      threads = Array.new(10) do
        Thread.new do
          runtime.dispatch_flat("Wire::Wire.Ask", reference: { value: "race" }, amount: { cents: 1 },
                           source: "left", destination: "right")
        rescue StandardError
          # a losing thread may be refused downstream; irrelevant here
          nil
        end
      end
      threads.each(&:join)

      born_count = runtime.sagas.count { |s| s[:process_manager] == "Carry" && s[:instance] == "race" && s[:born] }
      expect(born_count).to eq(1)
    end
  end
end
