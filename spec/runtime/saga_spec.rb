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
      hash_including(dispatch: "Drawer.Put", delivered: false,
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
  #
  # This leg is the FIRST one — nothing was ever taken — so once retries are
  # exhausted there is genuinely nothing for the compensating leg to put
  # back. The next test crashes the SECOND leg instead, where there is.
  it "retries a crashing leg MAX_DEFECT_RETRIES times, then gives up cleanly with nothing to undo" do
    runtime = funded
    real_reenter = runtime.method(:reenter)
    attempts = 0
    runtime.define_singleton_method(:reenter) do |verb, **args|
      if verb == "Wire::Drawer.Take"
        attempts += 1
        raise NoMethodError, "undefined method `boom' for nil"
      end

      real_reenter.call(verb, **args)
    end

    result = nil
    expect {
      result = runtime.dispatch("Wire::Wire.Ask",
                                reference: { value: "wire-defect" }, amount: { cents: 500 },
                                source: "left", destination: "right")
    }.to output(/Carry.*wire-defect.*Drawer\.Take.*after 4 attempts.*boom/m).to_stderr

    expect(result.events.map(&:name)).to eq(["WireAsked"])
    expect(Wire::Wire.find("wire-defect").status).to eq("asked")

    # Every attempt actually ran — bounded retry, not a single shot before
    # giving up.
    expect(attempts).to eq(Hecksagain::Runtime::SagaInterpreter::MAX_DEFECT_RETRIES + 1)

    # The money never left — the leg that would have taken it crashed on
    # every attempt.
    expect(Wire::Drawer.find("left").cents.to_h).to eq(cents: 10_000)

    take_log = runtime.sagas.select { |s| s[:dispatch] == "Drawer.Take" }
    expect(take_log.count { |s| s[:retrying] }).to eq(3)
    expect(take_log.last).to include(delivered: false, defect: true, defect_compensated: true,
                                     error_class: "NoMethodError")

    # Compensation is ATTEMPTED now — the defect path always unwinds once
    # retries are exhausted — but this leg is the first one: the instance is
    # still in "asked", the compensating leg is declared from "carrying",
    # and the mismatch means it finds nothing to put back rather than
    # putting back something that was never taken.
    expect(runtime.sagas).to include(
      hash_including(on: "refused", advanced: false, reason: 'in "asked", not "carrying"')
    )
    expect(runtime.registry.saga_instances["Carry"]["wire-defect"][:state]).to eq("asked")
  end

  # The crash lands on the SECOND leg instead — `Take` already ran for real,
  # so there is real money out of "left" by the time the credit leg starts
  # failing. Once MAX_DEFECT_RETRIES is exhausted, `unwind` runs the exact
  # same compensating leg a domain refusal would trigger, and the money
  # comes back with nobody dispatching anything by hand.
  it "retries a crashing leg, then compensates for real once retries are exhausted" do
    runtime = funded
    real_reenter = runtime.method(:reenter)
    attempts = 0
    runtime.define_singleton_method(:reenter) do |verb, **args|
      if verb == "Wire::Drawer.Put" && args[:number] == "right"
        attempts += 1
        raise NoMethodError, "undefined method `boom' for nil"
      end

      real_reenter.call(verb, **args)
    end

    expect {
      runtime.dispatch("Wire::Wire.Ask",
                       reference: { value: "wire-crash" }, amount: { cents: 1_000 },
                       source: "left", destination: "right")
    }.to output(/Carry.*wire-crash.*Drawer\.Put.*after 4 attempts.*boom/m).to_stderr

    expect(attempts).to eq(Hecksagain::Runtime::SagaInterpreter::MAX_DEFECT_RETRIES + 1)

    expect(Wire::Drawer.find("left").cents.to_h).to eq(cents: 10_000)
    expect(Wire::Wire.find("wire-crash").status).to eq("returned")
    expect(runtime.registry.saga_instances["Carry"]["wire-crash"][:state]).to eq("returned")

    expect(runtime.sagas).to include(
      hash_including(process_manager: "Carry", instance: "wire-crash", dispatch: "Drawer.Put",
                     delivered: false, defect: true, defect_compensated: true, error_class: "NoMethodError")
    )
  end

  # The reaction-depth ceiling isn't a domain decision either, but unlike a
  # crash there's nothing ambiguous about it — the leg unambiguously did not
  # run — so it unwinds on the FIRST hit, no retry involved. Stubbed rather
  # than actually built five deep : the THIRD `reaction_depth_reached?` check
  # in this chain is the credit leg's own (1: Take, 2: Wire.Moved, 3:
  # Drawer.Put into "right"), so tripping only that one leaves Take free to
  # actually run — real money to put back — and leaves the compensating
  # leg's own two dispatches free to run too, proving this produces a REAL
  # compensation, not just a logged, inert refusal-shaped record.
  it "unwinds when the reaction-depth ceiling is hit, not just when the domain refuses" do
    runtime = funded
    checks = 0
    runtime.define_singleton_method(:reaction_depth_reached?) do
      checks += 1
      checks == 3
    end

    runtime.dispatch("Wire::Wire.Ask",
                     reference: { value: "wire-ceiling" }, amount: { cents: 1_000 },
                     source: "left", destination: "right")

    expect(runtime.sagas).to include(
      hash_including(process_manager: "Carry", instance: "wire-ceiling", dispatch: "Drawer.Put",
                     delivered: false, reason: "reaction depth 5 reached")
    )

    expect(Wire::Drawer.find("left").cents.to_h).to eq(cents: 10_000)
    expect(Wire::Wire.find("wire-ceiling").status).to eq("returned")
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
