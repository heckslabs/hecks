
require "spec_helper"

WIRE_BLUEBOOK = File.join(InMemoryDomain::ROOT, "spec/fixtures/settlement.bluebook")

RSpec.describe "a process manager" do
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
    runtime.dispatch("Wire::Drawer.Open", number: { value: "left" })
    runtime.dispatch("Wire::Drawer.Open", number: { value: "right" })
    runtime.dispatch("Wire::Drawer.Put",  number: { value: "left" }, amount: { cents: 10_000 })
    runtime
  end

  it "carries a wire end to end — exact cents, exact states — and retires" do
    runtime = funded
    runtime.dispatch("Wire::Wire.Ask",
                     reference: { value: "wire-1" }, amount: { cents: 2_500 }, source: "left", destination: "right")

    expect(Wire::Drawer.find("left").cents.to_h).to  eq(cents: 7_500)
    expect(Wire::Drawer.find("right").cents.to_h).to eq(cents: 2_500)
    expect(Wire::Wire.find("wire-1").status).to eq("landed")

    expect(runtime.sagas.select { |s| s[:ended] }).to contain_exactly(
      hash_including(process_manager: "Carry", instance: "wire-1", ended: true)
    )
    expect(runtime.registry.saga_instances["Carry"]).to be_empty
  end

  it "remembers the opening payload — the credit leg reads a destination no event carried" do
    runtime = funded
    runtime.dispatch("Wire::Wire.Ask",
                     reference: { value: "wire-1" }, amount: { cents: 100 }, source: "left", destination: "right")

    expect(Wire::Drawer.find("right").cents.to_h).to eq(cents: 100)
  end

  # A refused leg UNWINDS the legs that already happened. Nobody has to notice.
  #
  # This test used to assert the opposite and call it "the compensation puts the
  # money back" — but it was the TEST that put the money back, by hand, on the
  # line after asserting the drawer was short. Between those two dispatches the
  # thousand was nowhere: taken from the source, refused by the destination, and
  # no part of the system trying to recover it. A drawer that cannot be paid into
  # is an ordinary Tuesday. Money vanishing because of it is not.
  it "unwinds a refused leg on its own, without anyone noticing" do
    runtime = funded
    runtime.dispatch("Wire::Drawer.Shut", number: { value: "right" })
    runtime.dispatch("Wire::Wire.Ask",
                     reference: { value: "wire-2" }, amount: { cents: 1_000 }, source: "left", destination: "right")

    # The refusal is still recorded — a fact about the domain, not a crash.
    expect(runtime.sagas).to include(
      hash_including(dispatch: "Wire::Drawer.Put", delivered: false,
                     reason: "Put refused — the drawer is open")
    )

    # And the money is back, because the Take declared what makes it good again.
    expect(Wire::Drawer.find("left").cents.to_h).to eq(cents: 10_000)
    expect(Wire::Wire.find("wire-2").status).to eq("returned")
  end

  it "ignores an uncorrelated event — a manual Take is just a take" do
    runtime = funded
    runtime.dispatch("Wire::Drawer.Take", number: { value: "left" }, amount: { cents: 500 })

    expect(runtime.sagas).to be_empty
    expect(Wire::Drawer.find("left").cents.to_h).to eq(cents: 9_500)
  end

  # Same split as the policy interpreter, proven end to end through the same
  # `Dispatcher#dispatch` a real caller uses: `Wire.Ask` has already
  # succeeded and persisted `WireAsked` by the time the procedure's own
  # first leg (`Wire::Drawer.Take`) runs, and a genuine defect in THAT leg
  # must not reach back and fail `Ask`'s own dispatch.
  #
  # `reenter` is overridden on this one `runtime`, not stubbed with a
  # mocking framework — same technique, and same reasoning, as
  # `spec/runtime/policy_spec.rb`'s equivalent test: only the one verb this
  # test means to break is intercepted, everything else runs unmodified.
  it "keeps the triggering command's own success, and skips unwind, when a saga leg is a defect not a refusal" do
    runtime = funded
    real_reenter = runtime.method(:reenter)
    runtime.define_singleton_method(:reenter) do |verb, **args|
      raise NoMethodError, "undefined method `boom' for nil" if verb == "Wire::Drawer.Take"

      real_reenter.call(verb, **args)
    end

    result = nil
    expect {
      result = runtime.dispatch("Wire::Wire.Ask",
                                reference: { value: "wire-defect" }, amount: { cents: 500 },
                                source: "left", destination: "right")
    }.to output(/Carry.*wire-defect.*Wire::Drawer\.Take.*boom/m).to_stderr

    expect(result.events.map(&:name)).to eq(["WireAsked"])
    expect(Wire::Wire.find("wire-defect").status).to eq("asked")

    # The money never left — the leg that would have taken it is exactly
    # the one that crashed instead of running.
    expect(Wire::Drawer.find("left").cents.to_h).to eq(cents: 10_000)

    expect(runtime.sagas).to include(
      hash_including(process_manager: "Carry", instance: "wire-defect", dispatch: "Wire::Drawer.Take",
                     delivered: false, defect: true, error_class: "NoMethodError")
    )

    # NO unwind : `on :refused` never fires for a defect, so the instance
    # stays exactly where it landed rather than moving to "returned".
    expect(runtime.sagas).not_to include(hash_including(on: "refused"))
    expect(runtime.registry.saga_instances["Carry"]["wire-defect"][:state]).to eq("asked")
  end

  it "records an event that arrives in the wrong phase, and does not advance" do
    runtime = funded
    runtime.dispatch("Wire::Drawer.Shut", number: { value: "right" })
    runtime.dispatch("Wire::Wire.Ask",
                     reference: { value: "wire-3" }, amount: { cents: 100 }, source: "left", destination: "right")
    # No manual Wire.Returned any more — the refused leg unwinds on its own, and
    # the compensation's own Put emits PutIn while the procedure sits in
    # "returned". Which IS the wrong phase, arriving without being arranged.

    expect(runtime.sagas).to include(
      hash_including(on: "PutIn", advanced: false,
                     reason: 'in "returned", not "carrying"')
    )
  end
end

RSpec.describe "a lifecycle" do
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
    runtime.dispatch("Wire::Drawer.Open", number: { value: "d" })

    expect(Wire::Drawer.find("d").status).to eq("open")
  end

  it "applies the transition the command names" do
    runtime = boot_wire
    runtime.dispatch("Wire::Drawer.Open", number: { value: "d" })
    runtime.dispatch("Wire::Drawer.Shut", number: { value: "d" })

    expect(Wire::Drawer.find("d").status).to eq("shut")
  end

  it "refuses a move the machine does not admit, in so many words" do
    runtime = boot_wire
    runtime.dispatch("Wire::Drawer.Open", number: { value: "d" })
    runtime.dispatch("Wire::Drawer.Shut", number: { value: "d" })

    expect { runtime.dispatch("Wire::Drawer.Shut", number: { value: "d" }) }
      .to raise_error(Hecksagain::Runtime::LifecycleRefused,
                      'Shut refused — status is "shut", and Shut moves it only from "open"')
  end

  it "addresses a record by its reference key, like every saga leg must" do
    runtime = boot_wire
    # the drawers have to exist — a wire between accounts that were never
    # opened is not a wire, and the runtime now says so
    runtime.dispatch("Wire::Drawer.Open", number: { value: "a" })
    runtime.dispatch("Wire::Drawer.Open", number: { value: "b" })
    runtime.dispatch("Wire::Wire.Ask", reference: { value: "w" }, amount: { cents: 1 }, source: "a", destination: "b")

    # The message now names the declared PATH ("reference.value"), not just its
    # head — more precise than the bare field name, and what `identity_reading`
    # quotes for every construct now, not something special-cased for Wire.
    expect { runtime.dispatch("Wire::Wire.Returned", wire: "missing") }
      .to raise_error(Hecksagain::Runtime::NotFound, /no Wire with reference\.value "missing"/)
  end
end
