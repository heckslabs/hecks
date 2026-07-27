# frozen_string_literal: true

require "spec_helper"

# THE CONVERSATION THAT OUTLIVES A COMMAND, pinned where the truth lives.
#
# Settlement parsed, reached the IR, was agreed on byte-for-byte by both
# parsers — and ran nowhere, in either runtime. These examples pin what the
# Ruby runtime means by a process manager, to the exact cent : born with the
# opening payload as memory, advanced transition-first, `with:` symbols
# resolving correlation → event payload → memory, refused legs recorded and
# never propagated, ended on ends_on and retired. The lifecycle and
# reference-key examples pin the two constructs every saga leg stands on.
RSpec.describe "a process manager" do
  WIRE_BLUEBOOK = File.join(InMemoryDomain::ROOT, "spec/fixtures/settlement.bluebook")

  def boot_wire
    registry = Hecksagain::Runtime::Registry.new

    Hecksagain.with_registry(registry) do
      Kernel.load(InMemoryDomain::PERSISTENCE_PORT)
      Kernel.load(InMemoryDomain::EXTRACTION_PORT)
      Kernel.load(InMemoryDomain::MEMORY_ADAPTER)
      Kernel.load(InMemoryDomain::PRISM_ADAPTER)
      Kernel.load(WIRE_BLUEBOOK)
      Hecksagain::Runtime::Loader.bind_runtime(
        Hecksagain::Runtime::Dispatcher.new(registry)
      )
    end
  end

  # Two drawers, one funded. Returns the runtime.
  def funded(runtime = boot_wire)
    runtime.dispatch("Wire::Drawer.Open", id: "left")
    runtime.dispatch("Wire::Drawer.Open", id: "right")
    runtime.dispatch("Wire::Drawer.Put",  id: "left", amount: 10_000)
    runtime
  end

  it "carries a wire end to end — exact cents, exact states — and retires" do
    runtime = funded
    runtime.dispatch("Wire::Wire.Ask",
                     id: "wire-1", amount: 2_500, source: "left", destination: "right")

    expect(Wire::Drawer.find("left").cents).to  eq(7_500)
    expect(Wire::Drawer.find("right").cents).to eq(2_500)
    expect(Wire::Wire.find("wire-1").status).to eq("landed")

    # The whole conversation is on the log, in order — and the instance is
    # RETIRED : ends_on means ended, not parked.
    expect(runtime.sagas.select { |s| s[:ended] }).to contain_exactly(
      hash_including(process_manager: "Carry", instance: "wire-1", ended: true)
    )
    expect(runtime.registry.saga_instances["Carry"]).to be_empty
  end

  it "remembers the opening payload — the credit leg reads a destination no event carried" do
    runtime = funded
    runtime.dispatch("Wire::Wire.Ask",
                     id: "wire-1", amount: 100, source: "left", destination: "right")

    # `Taken`'s payload names the SOURCE drawer ; the destination exists only
    # in the remembered WireAsked payload. Money landing on the right proves
    # memory resolution, not payload luck.
    expect(Wire::Drawer.find("right").cents).to eq(100)
  end

  it "records a refused leg, and the compensation puts the money back" do
    runtime = funded
    runtime.dispatch("Wire::Drawer.Shut", id: "right")
    runtime.dispatch("Wire::Wire.Ask",
                     id: "wire-2", amount: 1_000, source: "left", destination: "right")

    # The source gave it up ; the destination refused it ; nothing pretended.
    expect(Wire::Drawer.find("left").cents).to eq(9_000)
    expect(runtime.sagas).to include(
      hash_including(dispatch: "Wire::Drawer.Put", delivered: false,
                     reason: "Put refused — the drawer is open")
    )

    # The back office returns it — the wire hears its own reversal and the
    # saga's compensating leg credits the source from MEMORY.
    runtime.dispatch("Wire::Wire.Returned", wire: "wire-2")
    expect(Wire::Drawer.find("left").cents).to eq(10_000)
    expect(Wire::Wire.find("wire-2").status).to eq("returned")
  end

  it "ignores an uncorrelated event — a manual Take is just a take" do
    runtime = funded
    runtime.dispatch("Wire::Drawer.Take", id: "left", amount: 500)

    expect(runtime.sagas).to be_empty
    expect(Wire::Drawer.find("left").cents).to eq(9_500)
  end

  it "records an event that arrives in the wrong phase, and does not advance" do
    runtime = funded
    runtime.dispatch("Wire::Drawer.Shut", id: "right")
    runtime.dispatch("Wire::Wire.Ask",
                     id: "wire-3", amount: 100, source: "left", destination: "right")
    runtime.dispatch("Wire::Wire.Returned", wire: "wire-3")

    # The compensation Put emits PutIn carrying the wire — but the
    # conversation has already moved to "returned", and the log says so
    # rather than saying nothing.
    expect(runtime.sagas).to include(
      hash_including(on: "PutIn", advanced: false,
                     reason: 'in "returned", not "carrying"')
    )
  end
end

RSpec.describe "a lifecycle" do
  WIRE_BLUEBOOK = File.join(InMemoryDomain::ROOT, "spec/fixtures/settlement.bluebook")

  def boot_wire
    registry = Hecksagain::Runtime::Registry.new

    Hecksagain.with_registry(registry) do
      Kernel.load(InMemoryDomain::PERSISTENCE_PORT)
      Kernel.load(InMemoryDomain::EXTRACTION_PORT)
      Kernel.load(InMemoryDomain::MEMORY_ADAPTER)
      Kernel.load(InMemoryDomain::PRISM_ADAPTER)
      Kernel.load(WIRE_BLUEBOOK)
      Hecksagain::Runtime::Loader.bind_runtime(
        Hecksagain::Runtime::Dispatcher.new(registry)
      )
    end
  end

  it "is born at its default — the field exists before any transition" do
    runtime = boot_wire
    runtime.dispatch("Wire::Drawer.Open", id: "d")

    expect(Wire::Drawer.find("d").status).to eq("open")
  end

  it "applies the transition the command names" do
    runtime = boot_wire
    runtime.dispatch("Wire::Drawer.Open", id: "d")
    runtime.dispatch("Wire::Drawer.Shut", id: "d")

    expect(Wire::Drawer.find("d").status).to eq("shut")
  end

  it "refuses a move the machine does not admit, in so many words" do
    runtime = boot_wire
    runtime.dispatch("Wire::Drawer.Open", id: "d")
    runtime.dispatch("Wire::Drawer.Shut", id: "d")

    expect { runtime.dispatch("Wire::Drawer.Shut", id: "d") }
      .to raise_error(Hecksagain::Runtime::LifecycleRefused,
                      'Shut refused — status is "shut", and Shut moves it only from "open"')
  end

  it "addresses a record by its reference key, like every saga leg must" do
    runtime = boot_wire
    runtime.dispatch("Wire::Wire.Ask", id: "w", amount: 1, source: "a", destination: "b")

    # `Returned` takes `wire:` because `reference_to Wire` SAYS so — the
    # spelling the whole saga surface refused with "pass id:" until
    # hydrate learned the convention Hecks locked long ago.
    expect { runtime.dispatch("Wire::Wire.Returned", wire: "missing") }
      .to raise_error(Hecksagain::Runtime::NotFound, /no Wire with id "missing"/)
  end
end
