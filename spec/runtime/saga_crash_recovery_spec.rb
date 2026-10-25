require "spec_helper"
require "tmpdir"

# Kills the process (a non-`StandardError`, which `deliver_saga_dispatch` does not rescue) inside
# the first leg, after the checkpoint is written, and inspects what the durable store holds.
RSpec.describe "saga durability across a process death mid-leg" do
  WIRE_BLUEBOOK  = File.join(InMemoryDomain::ROOT, "spec/fixtures/settlement.bluebook") unless defined?(WIRE_BLUEBOOK)
  SQLITE_ADAPTER = File.join(InMemoryDomain::ROOT, "lib/hecks/adapters/driven/sqlite.adapter") unless defined?(SQLITE_ADAPTER)

  SAGA_STALL_WARNING = /
    Wire\ Carry\ instance\ "wire-1"\ stalled\ before\ Drawer\.Take\ settled.*
    not\ declared\ idempotent.*reconcile\ this\ instance\ by\ hand
  /x

  around do |example|
    @dir = Dir.mktmpdir("hecks-saga-crash-")
    example.run
  ensure
    FileUtils.remove_entry(@dir) if @dir
  end

  def bind_wire_hecksagons(root)
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

  def declare_wire(root)
    Kernel.load(InMemoryDomain::PERSISTENCE_PORT)
    Kernel.load(InMemoryDomain::EXTRACTION_PORT)
    Kernel.load(InMemoryDomain::MEMORY_ADAPTER)
    Kernel.load(SQLITE_ADAPTER)
    Kernel.load(InMemoryDomain::PRISM_ADAPTER)
    Kernel.load(@wire_bluebook || WIRE_BLUEBOOK)
    bind_wire_hecksagons(root)
  end

  # Boots against SqlitePersistence: a Memory-only marker would not show what a real crash leaves.
  def boot_wire(root: @dir)
    registry = Hecks::Runtime::Registry.new(root: root)

    Hecks.with_registry(registry) { declare_wire(root) }

    registry.verify!
    registry.rehydrate_sagas!
    Hecks::Runtime::Loader.bind_runtime(Hecks::Runtime::Dispatcher.new(registry)).tap(&:redrive_sagas!)
  end

  class SimulatedCrash < Exception; end # rubocop:disable Lint/InheritException

  let(:runtime) { boot_wire }

  def fund_left_drawer
    runtime.dispatch_flat("Wire::Drawer.Open", number: { value: "left" })
    runtime.dispatch_flat("Wire::Drawer.Open", number: { value: "right" })
    runtime.dispatch_flat("Wire::Drawer.Put",  number: { value: "left" }, amount: { cents: 10_000 })
  end

  def ask_wire
    runtime.dispatch_flat("Wire::Wire.Ask", reference: { value: "wire-1" }, amount: { cents: 2_500 },
                          source: "left", destination: "right")
  end

  # `Drawer::Take` is the first `Carry` leg; crash on it before it does anything.
  def crash_on_take(bare_calls: false)
    allow(runtime).to receive(:reenter).and_wrap_original do |original, *args, **kwargs|
      raise SimulatedCrash, "the process died right here" if (bare_calls && kwargs.empty?) || args.first&.include?("Take")

      original.call(*args, **kwargs)
    end
  end

  def carry_row = runtime.registry.saga_persistence("Wire").each_saga.to_a.find { |r| r[0] == "Carry" }

  def ask_and_die
    ask_wire
  rescue SimulatedCrash
    nil # the "process" died — a fresh boot against the same store is what happens next
  end

  # A fresh boot against the store a crash left behind; the stall must be reported on STDERR.
  def reopened_after_crash
    fund_left_drawer
    crash_on_take
    ask_and_die
    reopened = nil
    expect { reopened = boot_wire }.to output(SAGA_STALL_WARNING).to_stderr
    reopened
  end

  describe "the store a crash leaves" do
    def crash_during_ask
      fund_left_drawer
      crash_on_take(bare_calls: true)
      expect { ask_wire }.to raise_error(SimulatedCrash)
    end

    # The leg never ran: the source drawer was not debited.
    it "leaves the leg's own dispatch unrun" do
      crash_during_ask

      expect(Wire::Drawer.find("left").cents.to_h).to eq(cents: 10_000)
    end

    # The checkpoint is already durable, with a marker for the unconfirmed leg.
    it "leaves the checkpointed state", :aggregate_failures do
      crash_during_ask

      expect(carry_row).not_to be_nil
      expect(carry_row.first(3)).to eq(["Carry", "wire-1", "asked"])
    end

    it "leaves a durable pending marker for the unconfirmed leg" do
      crash_during_ask

      expect(carry_row[3][:__hecks_saga_pending_dispatch__])
        .to include(on: "WireAsked", from: "asked", to: "asked", dispatches: ["Drawer.Take"])
    end
  end

  # A store that keeps no dispatch claims, so only the command's own declaration can make a started
  # dispatch safe to deliver again.
  def store_without_dispatch_claims
    allow(Hecks::Runtime::DispatchClaim).to receive(:supported?).and_return(false)
  end

  describe "rehydrating a store that dedupes nothing" do
    before { store_without_dispatch_claims }

    # Surfaced: state restored and the stall is on record.
    it "surfaces the stall loudly", :aggregate_failures do
      reopened = reopened_after_crash

      expect(reopened.registry.saga_instances["Carry"]["wire-1"]).to include(state: "asked")
      expect(reopened.registry.saga_log).to include(
        hash_including(process_manager: "Carry", instance: "wire-1", rehydrated_stalled: true)
      )
    end

    # The reserved marker must not leak into live memory, where a `given` or `with:` would see it.
    it "keeps the reserved marker out of live memory" do
      memory = reopened_after_crash.registry.saga_instances["Carry"]["wire-1"][:memory]

      expect(memory).not_to have_key(:__hecks_saga_pending_dispatch__)
    end

    # The dispatch was started, so it may have run; a command not declared idempotent is not
    # redelivered (see saga_pending_dispatch.rb).
    it "does NOT redrive a started dispatch that is not declared idempotent", :aggregate_failures do
      reopened_after_crash

      expect(Wire::Drawer.find("left").cents.to_h).to eq(cents: 10_000)
      expect(Wire::Drawer.find("right").cents.to_h).to eq(cents: 0)
    end
  end

  describe "redriving the stalled leg" do
    # The crash is moved back to just after the checkpoint: no dispatch of the leg had begun.
    def rewind_to_unstarted
      process_manager, correlation, state, memory, compensations = carry_row
      memory[:__hecks_saga_pending_dispatch__].merge!(settled: 0, attempting: false)
      runtime.registry.saga_persistence("Wire").save_saga(
        process_manager: process_manager, correlation: correlation, state: state, memory: memory,
        completed_compensations: compensations
      )
    end

    # The fixture with `idempotent` written into `Take`. `Take` only stands in here: the example
    # proves the declaration reaches the redrive, not that taking money twice is harmless.
    def declare_take_idempotent
      declared = File.read(WIRE_BLUEBOOK).sub(%(command "Take" do\n), %(command "Take" do\n      idempotent\n))
      @wire_bluebook = File.join(@dir, "settlement.bluebook")
      File.write(@wire_bluebook, declared)
    end

    def crash_then_reboot
      fund_left_drawer
      crash_on_take
      ask_and_die
      yield if block_given?
      boot_wire
    end

    it "delivers every dispatch of a leg that never began", :aggregate_failures do
      reopened = crash_then_reboot { rewind_to_unstarted }

      expect(Wire::Drawer.find("left").cents.to_h).to eq(cents: 7_500)
      expect(Wire::Drawer.find("right").cents.to_h).to eq(cents: 2_500)
      expect(reopened.registry.saga_log).to include(hash_including(process_manager: "Carry", redriven: true))
    end

    it "clears the marker once the leg is finished" do
      crash_then_reboot { rewind_to_unstarted }

      expect(Array(carry_row)[3].to_h).not_to have_key(:__hecks_saga_pending_dispatch__)
    end

    it "does not deliver twice when the store is reopened again", :aggregate_failures do
      crash_then_reboot { rewind_to_unstarted }
      boot_wire

      expect(Wire::Drawer.find("left").cents.to_h).to eq(cents: 7_500)
      expect(Wire::Drawer.find("right").cents.to_h).to eq(cents: 2_500)
    end

    it "redelivers a started dispatch whose command is declared idempotent", :aggregate_failures do
      store_without_dispatch_claims
      declare_take_idempotent
      crash_then_reboot

      expect(Wire::Drawer.find("left").cents.to_h).to eq(cents: 7_500)
      expect(Wire::Drawer.find("right").cents.to_h).to eq(cents: 2_500)
    end
  end

  describe "redriving through the store's dispatch claims" do
    # The crash comes after `Take` committed but before the saga recorded it as settled: the
    # ambiguous case, with the money already out of the drawer.
    def die_after_take_committed
      fund_left_drawer
      allow(runtime).to receive(:reenter).and_wrap_original do |original, *args, **kwargs|
        original.call(*args, **kwargs).tap { raise SimulatedCrash, "died after the commit" if args.first.include?("Take") }
      end
      ask_and_die
    end

    def expect_transfer_applied_once
      expect(Wire::Drawer.find("left").cents.to_h).to eq(cents: 7_500)
      expect(Wire::Drawer.find("right").cents.to_h).to eq(cents: 2_500)
    end

    # `Take` is not declared idempotent and decrements: only the store's claim can make it safe.
    it "applies a dispatch that never ran, once" do
      fund_left_drawer
      crash_on_take
      ask_and_die
      boot_wire

      expect_transfer_applied_once
    end

    it "does not apply a dispatch that had already committed a second time" do
      die_after_take_committed
      boot_wire

      expect_transfer_applied_once
    end
  end
end
