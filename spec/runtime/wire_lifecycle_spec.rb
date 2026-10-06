require "spec_helper"

WIRE_LIFECYCLE_BLUEBOOK = File.join(InMemoryDomain::ROOT, "spec/fixtures/settlement.bluebook")

RSpec.describe "a lifecycle" do
  def boot_wire
    registry = Hecks::Runtime::Registry.new

    Hecks.with_registry(registry) do
      Kernel.load(InMemoryDomain::PERSISTENCE_PORT)
      Kernel.load(InMemoryDomain::EXTRACTION_PORT)
      Kernel.load(InMemoryDomain::MEMORY_ADAPTER)
      Kernel.load(InMemoryDomain::PRISM_ADAPTER)
      Kernel.load(WIRE_LIFECYCLE_BLUEBOOK)
      Hecks::Runtime::Loader.bind_runtime(Hecks::Runtime::Dispatcher.new(registry))
    end
  end

  let(:runtime) { boot_wire }

  def drawer(verb, number) = runtime.dispatch_flat("Wire::Drawer.#{verb}", number: { value: number })

  it "is born at its default — the field exists before any transition" do
    drawer("Open", "d")

    expect(Wire::Drawer.find("d").status).to eq("open")
  end

  it "applies the transition the command names" do
    drawer("Open", "d")
    drawer("Shut", "d")

    expect(Wire::Drawer.find("d").status).to eq("shut")
  end

  it "refuses a move the machine does not admit, in so many words" do
    drawer("Open", "d")
    drawer("Shut", "d")

    expect { drawer("Shut", "d") }
      .to raise_error(Hecks::Runtime::LifecycleRefused,
                      'Shut refused — status is "shut", and Shut moves it only from "open"')
  end

  it "addresses a record by its reference key, like every saga leg must" do
    # a wire between drawers that were never opened is refused
    drawer("Open", "a")
    drawer("Open", "b")
    runtime.dispatch_flat("Wire::Wire.Ask", reference: { value: "w" }, amount: { cents: 1 }, source: "a", destination: "b")

    # The message names the declared path ("reference.value"), as identity_reading does everywhere.
    expect { runtime.dispatch_flat("Wire::Wire.Returned", wire: "missing") }
      .to raise_error(Hecks::Runtime::NotFound, /no Wire with reference\.value "missing"/)
  end
end
