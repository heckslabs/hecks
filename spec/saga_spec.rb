
require "spec_helper"

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

    expect(runtime.sagas.select { |s| s[:ended] }).to contain_exactly(
      hash_including(process_manager: "Carry", instance: "wire-1", ended: true)
    )
    expect(runtime.registry.saga_instances["Carry"]).to be_empty
  end

  it "remembers the opening payload — the credit leg reads a destination no event carried" do
    runtime = funded
    runtime.dispatch("Wire::Wire.Ask",
                     id: "wire-1", amount: 100, source: "left", destination: "right")

    expect(Wire::Drawer.find("right").cents).to eq(100)
  end

  it "records a refused leg, and the compensation puts the money back" do
    runtime = funded
    runtime.dispatch("Wire::Drawer.Shut", id: "right")
    runtime.dispatch("Wire::Wire.Ask",
                     id: "wire-2", amount: 1_000, source: "left", destination: "right")

    expect(Wire::Drawer.find("left").cents).to eq(9_000)
    expect(runtime.sagas).to include(
      hash_including(dispatch: "Wire::Drawer.Put", delivered: false,
                     reason: "Put refused — the drawer is open")
    )

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

    expect { runtime.dispatch("Wire::Wire.Returned", wire: "missing") }
      .to raise_error(Hecksagain::Runtime::NotFound, /no Wire with id "missing"/)
  end
end
