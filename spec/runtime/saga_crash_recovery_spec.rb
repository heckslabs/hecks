require "spec_helper"
require "tmpdir"

# THE ACTUAL REGRESSION THE SAGA-DURABILITY REVIEW ASKED FOR A TEST ON —
# `advance_saga`/`unwind` checkpoint a saga's new state BEFORE the leg
# that justifies it runs (the mutex they hold is not reentrant, so it is
# released before `deliver_saga_dispatch` can recurse back through
# `@door.reenter`). Until now nothing killed the process in that window
# and looked at what the store was left holding. This does, by raising a
# non-`StandardError` (nothing in `deliver_saga_dispatch`'s own rescue
# ladder — `DOMAIN_REFUSALS`, `StandardError` — catches it, exactly the
# way a real SIGKILL or OOM wouldn't either) from inside the FIRST leg's
# own dispatch, so nothing after that point in `settle_transition` — not
# even its own "clear the pending marker" checkpoint — ever runs.
RSpec.describe "saga durability across a process death mid-leg" do
  WIRE_BLUEBOOK  = File.join(InMemoryDomain::ROOT, "spec/fixtures/settlement.bluebook")
  SQLITE_ADAPTER = File.join(InMemoryDomain::ROOT, "lib/hecks/adapters/driven/sqlite.adapter")

  around do |example|
    @dir = Dir.mktmpdir("hecks-saga-crash-")
    example.run
  ensure
    FileUtils.remove_entry(@dir) if @dir
  end

  # Same shape as `saga_durability_spec.rb`'s own `boot_wire` — a real
  # SqlitePersistence-backed boot, not the Memory one most saga specs
  # stay on, because a marker that only ever round-tripped through a
  # Ruby Hash would prove nothing about what a REAL crash leaves behind.
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
    registry.rehydrate_sagas!
    Hecks::Runtime::Loader.bind_runtime(Hecks::Runtime::Dispatcher.new(registry))
  end

  class SimulatedCrash < Exception; end # rubocop:disable Lint/InheritException

  it "leaves the checkpointed state AND a durable pending marker when the leg's own dispatch never ran" do
    runtime = boot_wire
    runtime.dispatch("Wire::Drawer.Open", number: { value: "left" })
    runtime.dispatch("Wire::Drawer.Open", number: { value: "right" })
    runtime.dispatch("Wire::Drawer.Put",  number: { value: "left" }, amount: { cents: 10_000 })

    # `WireAsked`'s own handler dispatches exactly one command
    # (`Drawer::Take`, settlement.bluebook's first `Carry` leg) — raise
    # on `reenter`'s FIRST call so this is the one that "crashes",
    # before `Take` itself does anything.
    allow(runtime).to receive(:reenter).and_wrap_original do |original, *args, **kwargs|
      raise SimulatedCrash, "the process died right here" if kwargs.empty? || args.first&.include?("Take")

      original.call(*args, **kwargs)
    end

    expect do
      runtime.dispatch("Wire::Wire.Ask", reference: { value: "wire-1" }, amount: { cents: 2_500 },
                       source: "left", destination: "right")
    end.to raise_error(SimulatedCrash)

    # The leg's own dispatch never happened — the source drawer was
    # never actually debited.
    expect(Wire::Drawer.find("left").cents.to_h).to eq(cents: 10_000)

    # But the checkpoint that was supposed to be JUSTIFIED by that
    # dispatch is already sitting in the real, durable store, with a
    # marker recording the leg that never confirmed.
    row = runtime.registry.saga_persistence("Wire").each_saga.to_a.find { |r| r[0] == "Carry" }
    expect(row).not_to be_nil
    process_manager, correlation, state, memory = row
    expect([process_manager, correlation, state]).to eq(["Carry", "wire-1", "asked"])
    expect(memory[:__hecks_saga_pending_dispatch__]).to include(
      on: "WireAsked", from: "asked", to: "asked", dispatches: ["Drawer.Take"]
    )
  end

  # One real crash-then-reboot scenario against the SAME durable store,
  # proving three things about the SAME stalled saga together (it's
  # surfaced loudly, the internal marker doesn't leak into live memory,
  # and nothing auto-redrives) — splitting would mean re-simulating the
  # crash for each, or losing that all three hold of one rehydration.
  # rubocop:disable-next RSpec/ExampleLength
  it "rehydrating that same store surfaces the stall loudly and does NOT auto-redrive the leg" do
    runtime = boot_wire
    runtime.dispatch("Wire::Drawer.Open", number: { value: "left" })
    runtime.dispatch("Wire::Drawer.Open", number: { value: "right" })
    runtime.dispatch("Wire::Drawer.Put",  number: { value: "left" }, amount: { cents: 10_000 })

    allow(runtime).to receive(:reenter).and_wrap_original do |original, *args, **kwargs|
      raise SimulatedCrash if args.first&.include?("Take")

      original.call(*args, **kwargs)
    end
    begin
      runtime.dispatch("Wire::Wire.Ask", reference: { value: "wire-1" }, amount: { cents: 2_500 },
                       source: "left", destination: "right")
    rescue SimulatedCrash
      nil # the "process" died — a fresh boot against the same store is what happens next
    end

    reopened = nil
    expect { reopened = boot_wire }.to output(
      /
        Wire\ rehydrated\ Carry\ instance\ "wire-1"\ in\ state\ "asked"\ with\ a\ dispatch\ left\ pending.*
        Take.*reconcile\ this\ instance\ by\ hand
      /x
    ).to_stderr

    # Surfaced (state restored, and the stall is on record)...
    expect(reopened.registry.saga_instances["Carry"]["wire-1"]).to include(state: "asked")
    expect(reopened.registry.saga_log).to include(
      hash_including(process_manager: "Carry", instance: "wire-1", rehydrated_stalled: true)
    )
    # ...but the reserved marker never leaks into the LIVE instance's own
    # memory (a `given`, a `with:` mapping, or a re-check of this same
    # saga would otherwise see an internal bookkeeping key no bluebook
    # ever declared).
    expect(reopened.registry.saga_instances["Carry"]["wire-1"][:memory]).not_to have_key(:__hecks_saga_pending_dispatch__)

    # And, deliberately, NOT auto-redriven — no compensating or
    # continuing dispatch ran just because the process rebooted. See
    # saga_pending_dispatch.rb for why: redelivering a dispatch whose
    # outcome is unknown is only safe with idempotent delivery, which
    # this pipeline doesn't have.
    expect(Wire::Drawer.find("left").cents.to_h).to eq(cents: 10_000)
    expect(Wire::Drawer.find("right").cents.to_h).to eq(cents: 0)
  end
end
