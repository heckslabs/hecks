require "spec_helper"
require "tmpdir"

# Kills the process (a non-`StandardError`, which `deliver_saga_dispatch` does not rescue) inside
# the first leg, after the checkpoint is written, and inspects what the durable store holds.
RSpec.describe "saga durability across a process death mid-leg" do
  WIRE_BLUEBOOK  = File.join(InMemoryDomain::ROOT, "spec/fixtures/settlement.bluebook") unless defined?(WIRE_BLUEBOOK)
  SQLITE_ADAPTER = File.join(InMemoryDomain::ROOT, "lib/hecks/adapters/driven/sqlite.adapter") unless defined?(SQLITE_ADAPTER)

  around do |example|
    @dir = Dir.mktmpdir("hecks-saga-crash-")
    example.run
  ensure
    FileUtils.remove_entry(@dir) if @dir
  end

  # Boots against SqlitePersistence: a Memory-only marker would not show what a real crash leaves.
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
    registry.rehydrate_sagas!
    Hecks::Runtime::Loader.bind_runtime(Hecks::Runtime::Dispatcher.new(registry))
  end

  class SimulatedCrash < Exception; end # rubocop:disable Lint/InheritException

  it "leaves the checkpointed state AND a durable pending marker when the leg's own dispatch never ran" do
    runtime = boot_wire
    runtime.dispatch_flat("Wire::Drawer.Open", number: { value: "left" })
    runtime.dispatch_flat("Wire::Drawer.Open", number: { value: "right" })
    runtime.dispatch_flat("Wire::Drawer.Put",  number: { value: "left" }, amount: { cents: 10_000 })

    # `Drawer::Take` is the first `Carry` leg; crash on it before it does anything.
    allow(runtime).to receive(:reenter).and_wrap_original do |original, *args, **kwargs|
      raise SimulatedCrash, "the process died right here" if kwargs.empty? || args.first&.include?("Take")

      original.call(*args, **kwargs)
    end

    expect do
      runtime.dispatch_flat("Wire::Wire.Ask", reference: { value: "wire-1" }, amount: { cents: 2_500 },
                       source: "left", destination: "right")
    end.to raise_error(SimulatedCrash)

    # The leg never ran: the source drawer was not debited.
    expect(Wire::Drawer.find("left").cents.to_h).to eq(cents: 10_000)

    # The checkpoint is already durable, with a marker for the unconfirmed leg.
    row = runtime.registry.saga_persistence("Wire").each_saga.to_a.find { |r| r[0] == "Carry" }
    expect(row).not_to be_nil
    process_manager, correlation, state, memory = row
    expect([process_manager, correlation, state]).to eq(["Carry", "wire-1", "asked"])
    expect(memory[:__hecks_saga_pending_dispatch__]).to include(
      on: "WireAsked", from: "asked", to: "asked", dispatches: ["Drawer.Take"]
    )
  end

  # One crash-then-reboot scenario proves three facts about the same stalled saga; splitting
  # would re-simulate the crash for each.
  # rubocop:disable-next RSpec/ExampleLength
  it "rehydrating that same store surfaces the stall loudly and does NOT auto-redrive the leg" do
    runtime = boot_wire
    runtime.dispatch_flat("Wire::Drawer.Open", number: { value: "left" })
    runtime.dispatch_flat("Wire::Drawer.Open", number: { value: "right" })
    runtime.dispatch_flat("Wire::Drawer.Put",  number: { value: "left" }, amount: { cents: 10_000 })

    allow(runtime).to receive(:reenter).and_wrap_original do |original, *args, **kwargs|
      raise SimulatedCrash if args.first&.include?("Take")

      original.call(*args, **kwargs)
    end
    begin
      runtime.dispatch_flat("Wire::Wire.Ask", reference: { value: "wire-1" }, amount: { cents: 2_500 },
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

    # Surfaced: state restored and the stall is on record.
    expect(reopened.registry.saga_instances["Carry"]["wire-1"]).to include(state: "asked")
    expect(reopened.registry.saga_log).to include(
      hash_including(process_manager: "Carry", instance: "wire-1", rehydrated_stalled: true)
    )
    # The reserved marker must not leak into live memory, where a `given` or `with:` would see it.
    expect(reopened.registry.saga_instances["Carry"]["wire-1"][:memory]).not_to have_key(:__hecks_saga_pending_dispatch__)

    # Not auto-redriven: redelivering a dispatch with an unknown outcome is unsafe without
    # idempotent delivery (see saga_pending_dispatch.rb).
    expect(Wire::Drawer.find("left").cents.to_h).to eq(cents: 10_000)
    expect(Wire::Drawer.find("right").cents.to_h).to eq(cents: 0)
  end
end
