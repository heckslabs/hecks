require "spec_helper"
require "tmpdir"

# §5/§6/§7 END TO END — the actual regression this whole phase exists
# to fix: a process manager sitting in a mid-flight (or, here, a
# terminal-but-never-cleaned-up) state survives a process restart,
# through a REAL adapter, not the Memory one `spec/runtime/saga_spec.rb`
# stays on. Uses the Wire fixture's own `Carry` saga
# (spec/fixtures/settlement.bluebook) bound to SqlitePersistence rather
# than a purpose-built fixture, the same "reuse the existing Carry
# process manager, re-bound to each adapter under test" the plan calls
# for.
#
# `Carry`'s own `on "WireAsked"`/`on "Taken"`/`on "PutIn"` legs all
# cascade SYNCHRONOUSLY within one `dispatch` call (`deliver_saga_
# dispatch` re-enters through the same door), so there is no publicly
# observable "waiting for a later, separate dispatch" window for the
# happy path. The `on :refused` leg is different: shutting the
# DESTINATION drawer before asking a wire makes `Wire::Drawer.Put`
# refuse, `unwind` moves the saga to `"returned"`, and `"returned"` has
# no further transition in this bluebook — a REAL, naturally-arising
# stuck state, structurally the same shape as Banking's own `Settlement`
# sitting in `"awaiting_credit"` this whole arc is about.
RSpec.describe "durable saga/process-manager state" do
  WIRE_BLUEBOOK = File.join(InMemoryDomain::ROOT, "spec/fixtures/settlement.bluebook")
  SQLITE_ADAPTER = File.join(InMemoryDomain::ROOT, "lib/hecksagain/adapters/driven/sqlite.adapter")

  around do |example|
    @dir = Dir.mktmpdir("hecksagain-saga-durability-")
    example.run
  ensure
    FileUtils.remove_entry(@dir) if @dir
  end

  def boot_wire(root: @dir)
    registry = Hecksagain::Runtime::Registry.new(root: root)

    Hecksagain.with_registry(registry) do
      Kernel.load(InMemoryDomain::PERSISTENCE_PORT)
      Kernel.load(InMemoryDomain::EXTRACTION_PORT)
      Kernel.load(InMemoryDomain::MEMORY_ADAPTER)
      Kernel.load(SQLITE_ADAPTER)
      Kernel.load(InMemoryDomain::PRISM_ADAPTER)
      Kernel.load(WIRE_BLUEBOOK)
      # §0's domain-level default — one bind covers both aggregates.
      Hecks.hecksagon("Wire") do
        uses_framework "Governance"
        persisted_by "SqlitePersistence"
      end
      Hecks.hecksagon("Governance") do
        Governance::RoleAssignment.persisted_by("Memory")
        Governance::RoleTransition.persisted_by("Memory")
      end
      Hecks.world("Wire") { persisted_by("SqlitePersistence") { database(File.join(root, "wire.db")) } }
    end

    registry.verify!
    # `Loader.boot`'s own sequence (verify! then rehydrate_sagas! then
    # the dispatcher) — replicated here rather than routed through
    # `Loader.boot` itself, since this spec loads its fixture files
    # directly (`Kernel.load`) rather than from a real bluebook
    # directory on disk, the same reason `banking_matrix_spec.rb`'s own
    # `boot` helper doesn't call `Loader.boot` either.
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

  it "writes a saga checkpoint through the real adapter as the saga advances, not just in-memory" do
    runtime = stuck_wire(boot_wire)

    expect(runtime.registry.saga_instances["Carry"]["wire-1"]).to include(state: "returned")

    adapter = runtime.registry.saga_persistence("Wire")
    rows = adapter.each_saga.to_a
    expect(rows).to contain_exactly(["Carry", "wire-1", "returned", hash_including(reference: { value: "wire-1" })])
  end

  it "deletes the checkpoint once a saga genuinely ends (the happy path, ends_on)" do
    runtime = boot_wire
    runtime.dispatch("Wire::Drawer.Open", number: { value: "left" })
    runtime.dispatch("Wire::Drawer.Open", number: { value: "right" })
    runtime.dispatch("Wire::Drawer.Put",  number: { value: "left" }, amount: { cents: 10_000 })
    runtime.dispatch("Wire::Wire.Ask",
                     reference: { value: "wire-1" }, amount: { cents: 2_500 }, source: "left", destination: "right")

    expect(runtime.registry.saga_instances["Carry"]).to be_empty
    expect(runtime.registry.saga_persistence("Wire").each_saga.to_a).to eq([])
  end

  it "REHYDRATES a stuck saga on a fresh boot against the same store — the actual regression" do
    stuck_wire(boot_wire)

    # A fresh Registry — no in-memory state carried over, only the
    # SAME sqlite file on disk. This is what a process restart/cold
    # start looks like.
    reopened = boot_wire

    expect(reopened.registry.saga_instances["Carry"]["wire-1"]).to include(
      state: "returned", memory: include(reference: { value: "wire-1" })
    )
  end

  it "rehydration is a real no-op for a domain with nothing stuck" do
    runtime = boot_wire
    runtime.dispatch("Wire::Drawer.Open", number: { value: "left" })

    reopened = boot_wire
    expect(reopened.registry.saga_instances["Carry"]).to be_empty
  end

  describe "the saga_mutex (§7)" do
    it "keeps two threads racing begin_saga on the SAME correlation from double-booking or losing a checkpoint" do
      registry = Hecksagain::Runtime::Registry.new
      Hecksagain.with_registry(registry) do
        Kernel.load(InMemoryDomain::PERSISTENCE_PORT)
        Kernel.load(InMemoryDomain::EXTRACTION_PORT)
        Kernel.load(InMemoryDomain::MEMORY_ADAPTER)
        Kernel.load(InMemoryDomain::PRISM_ADAPTER)
        Kernel.load(WIRE_BLUEBOOK)
        Hecks.hecksagon("Wire") do
          uses_framework "Governance"
          persisted_by "Memory"
        end
        Hecks.hecksagon("Governance") do
          Governance::RoleAssignment.persisted_by("Memory")
          Governance::RoleTransition.persisted_by("Memory")
        end
      end
      registry.verify!
      runtime = Hecksagain::Runtime::Loader.bind_runtime(Hecksagain::Runtime::Dispatcher.new(registry))

      runtime.dispatch("Wire::Drawer.Open", number: { value: "left" })
      runtime.dispatch("Wire::Drawer.Open", number: { value: "right" })
      runtime.dispatch("Wire::Drawer.Put",  number: { value: "left" }, amount: { cents: 10_000 })

      # Ten threads all asking the SAME wire reference concurrently —
      # the correlation collides on every one. Exactly one may WIN
      # (begin the saga instance); the rest must see it already exists
      # and quietly skip, never partially overwriting it. Without the
      # mutex covering the check-then-set, this is the exact race
      # `begin_saga`'s own `key?` check has always been vulnerable to,
      # now with real I/O in the critical section making the window
      # wider (Memory has no I/O, but the mutex protects the in-memory
      # mutation identically regardless of which adapter is behind it).
      threads = Array.new(10) do
        Thread.new do
          runtime.dispatch("Wire::Wire.Ask", reference: { value: "race" }, amount: { cents: 1 },
                           source: "left", destination: "right")
        rescue StandardError
          nil # a losing thread may see the destination already credited and refuse downstream — fine, not the point
        end
      end
      threads.each(&:join)

      # Exactly one saga instance ever existed for this correlation —
      # never corrupted into a partial/mixed state.
      born_count = runtime.sagas.count { |s| s[:process_manager] == "Carry" && s[:instance] == "race" && s[:born] }
      expect(born_count).to eq(1)
    end
  end
end
