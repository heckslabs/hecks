require "spec_helper"

WIRE_BLUEBOOK = File.join(InMemoryDomain::ROOT, "spec/fixtures/settlement.bluebook") unless defined?(WIRE_BLUEBOOK)

RSpec.describe "a process manager" do
  def boot_wire
    registry = Hecks::Runtime::Registry.new

    Hecks.with_registry(registry) do
      Kernel.load(InMemoryDomain::PERSISTENCE_PORT)
      Kernel.load(InMemoryDomain::EXTRACTION_PORT)
      Kernel.load(InMemoryDomain::MEMORY_ADAPTER)
      Kernel.load(InMemoryDomain::PRISM_ADAPTER)
      Kernel.load(WIRE_BLUEBOOK)
      Hecks::Runtime::Loader.bind_runtime(
        Hecks::Runtime::Dispatcher.new(registry)
      )
    end
  end

  def funded(runtime = boot_wire)
    runtime.dispatch_flat("Wire::Drawer.Open", number: { value: "left" })
    runtime.dispatch_flat("Wire::Drawer.Open", number: { value: "right" })
    runtime.dispatch_flat("Wire::Drawer.Put",  number: { value: "left" }, amount: { cents: 10_000 })
    runtime
  end

  it "carries a wire end to end — exact cents, exact states — and retires" do
    runtime = funded
    runtime.dispatch_flat("Wire::Wire.Ask",
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
    runtime.dispatch_flat("Wire::Wire.Ask",
                          reference: { value: "wire-1" }, amount: { cents: 100 }, source: "left", destination: "right")

    expect(Wire::Drawer.find("right").cents.to_h).to eq(cents: 100)
  end

  # No manual compensation: asserting the money is back must not depend on the test
  # putting it back by hand.
  it "unwinds a refused leg on its own, without anyone noticing" do
    runtime = funded
    runtime.dispatch_flat("Wire::Drawer.Shut", number: { value: "right" })
    runtime.dispatch_flat("Wire::Wire.Ask",
                          reference: { value: "wire-2" }, amount: { cents: 1_000 }, source: "left", destination: "right")

    expect(runtime.sagas).to include(
      hash_including(dispatch: "Drawer.Put", delivered: false,
                     reason: "Put refused — the drawer is open")
    )

    expect(Wire::Drawer.find("left").cents.to_h).to eq(cents: 10_000)
    expect(Wire::Wire.find("wire-2").status).to eq("returned")
  end

  # Without `.dup`, a `remember` mid-saga would also write into the logged starting event.
  it "seeds a fresh saga's own memory as a COPY of the starting event's payload, never the same object" do
    runtime = funded
    # A refused leg unwinds rather than ending, so the instance survives to be inspected;
    # a clean landing is reaped from saga_instances at once.
    runtime.dispatch_flat("Wire::Drawer.Shut", number: { value: "right" })
    result = runtime.dispatch_flat("Wire::Wire.Ask",
                                   reference: { value: "wire-2" }, amount: { cents: 1_000 },
                                   source: "left", destination: "right")

    started  = result.events.find { |event| event.name == "WireAsked" }
    instance = runtime.registry.saga_instances["Carry"]["wire-2"]

    expect(instance[:memory]).not_to equal(started.payload)
    expect(instance[:memory]).to eq(started.payload)
  end

  it "ignores an uncorrelated event — a manual Take is just a take" do
    runtime = funded
    runtime.dispatch_flat("Wire::Drawer.Take", number: { value: "left" }, amount: { cents: 500 })

    expect(runtime.sagas).to be_empty
    expect(Wire::Drawer.find("left").cents.to_h).to eq(cents: 9_500)
  end

  # A defect in the first leg (Drawer.Take) must not fail Ask's own dispatch, which has
  # already persisted WireAsked. `reenter` is overridden on this runtime, as in policy_spec.
  # Nothing was taken, so the compensating leg has nothing to put back.
  # One example: every assertion follows from the same crashing dispatch.
  # rubocop:disable-next RSpec/ExampleLength
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
    expect do
      result = runtime.dispatch_flat("Wire::Wire.Ask",
                                     reference: { value: "wire-defect" }, amount: { cents: 500 },
                                     source: "left", destination: "right")
    end.to output(/Carry.*wire-defect.*Drawer\.Take.*after 4 attempts.*boom/m).to_stderr

    expect(result.events.map(&:name)).to eq(["WireAsked"])
    expect(Wire::Wire.find("wire-defect").status).to eq("asked")

    expect(attempts).to eq(Hecks::Runtime::SagaInterpreter::MAX_DEFECT_RETRIES + 1)

    expect(Wire::Drawer.find("left").cents.to_h).to eq(cents: 10_000)

    take_log = runtime.sagas.select { |s| s[:dispatch] == "Drawer.Take" }
    expect(take_log.count { |s| s[:retrying] }).to eq(3)
    expect(take_log.last).to include(delivered: false, defect: true, defect_compensated: true,
                                     error_class: "NoMethodError")

    # Compensation is attempted, but the instance is still in "asked" and the compensating
    # leg is declared from "carrying", so nothing is put back.
    expect(runtime.sagas).to include(
      hash_including(on: "refused", advanced: false, reason: 'in "asked", not "carrying"')
    )
    expect(runtime.registry.saga_instances["Carry"]["wire-defect"][:state]).to eq("asked")
  end

  # The crash lands on the second leg, after Take moved real money out of "left";
  # once retries are exhausted, `unwind` runs the same compensating leg a refusal would.
  it "retries a crashing leg, then compensates for real once retries are exhausted" do
    runtime = funded
    real_reenter = runtime.method(:reenter)
    attempts = 0
    runtime.define_singleton_method(:reenter) do |verb, **args|
      if verb == "Wire::Drawer.Put" && args[:to] == "right"
        attempts += 1
        raise NoMethodError, "undefined method `boom' for nil"
      end

      real_reenter.call(verb, **args)
    end

    expect do
      runtime.dispatch_flat("Wire::Wire.Ask",
                            reference: { value: "wire-crash" }, amount: { cents: 1_000 },
                            source: "left", destination: "right")
    end.to output(/Carry.*wire-crash.*Drawer\.Put.*after 4 attempts.*boom/m).to_stderr

    expect(attempts).to eq(Hecks::Runtime::SagaInterpreter::MAX_DEFECT_RETRIES + 1)

    expect(Wire::Drawer.find("left").cents.to_h).to eq(cents: 10_000)
    expect(Wire::Wire.find("wire-crash").status).to eq("returned")
    expect(runtime.registry.saga_instances["Carry"]["wire-crash"][:state]).to eq("returned")

    expect(runtime.sagas).to include(
      hash_including(process_manager: "Carry", instance: "wire-crash", dispatch: "Drawer.Put",
                     delivered: false, defect: true, defect_compensated: true, error_class: "NoMethodError")
    )
  end

  # The depth ceiling unwinds on the first hit, with no retry. Stubbed so only the third
  # check (the credit leg's Drawer.Put) trips: Take really runs, so there is money to put back.
  it "unwinds when the reaction-depth ceiling is hit, not just when the domain refuses" do
    runtime = funded
    checks = 0
    runtime.define_singleton_method(:reaction_depth_reached?) do
      checks += 1
      checks == 3
    end

    runtime.dispatch_flat("Wire::Wire.Ask",
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
    runtime.dispatch_flat("Wire::Drawer.Shut", number: { value: "right" })
    runtime.dispatch_flat("Wire::Wire.Ask",
                          reference: { value: "wire-3" }, amount: { cents: 100 }, source: "left", destination: "right")
    # The unwind's own Put emits PutIn while the procedure sits in "returned".

    expect(runtime.sagas).to include(
      hash_including(on: "PutIn", advanced: false,
                     reason: 'in "returned", not "carrying"')
    )
  end

  # The log must come from the stored instance, not a second read of the handler, or
  # Properties.saga_advances_follow_declared_handlers could never fail. The stub answers
  # differently on a second `to_state` call; `to_state_calls` pins that it is read once.
  it "logs the saga instance's own real transition, not a second read of the handler that decided it" do
    runtime = funded
    pm = runtime.registry.bluebook("Wire").process_managers.find { |candidate| candidate.name == "Carry" }
    real_handler = pm.handler_for("WireAsked")
    real_to_state = real_handler.to_state

    to_state_calls = 0
    stub_handler = Struct.new(:event_type, :from_state, :dispatches)
                         .new(real_handler.event_type, real_handler.from_state, real_handler.dispatches)
    stub_handler.define_singleton_method(:to_state) do
      to_state_calls += 1
      to_state_calls == 1 ? real_to_state : "a_second_read_would_answer_this_instead"
    end

    real_handler_for = pm.method(:handler_for)
    pm.define_singleton_method(:handler_for) do |event, state = nil|
      event == "WireAsked" ? stub_handler : real_handler_for.call(event, state)
    end

    runtime.dispatch_flat("Wire::Wire.Ask",
                          reference: { value: "wire-log-fidelity" }, amount: { cents: 500 },
                          source: "left", destination: "right")

    entry = runtime.sagas.find { |s| s[:process_manager] == "Carry" && s[:on] == "WireAsked" && s[:advanced] }

    expect(to_state_calls).to eq(1)
    expect(entry[:to]).to eq(real_to_state)
    expect(entry[:to]).not_to eq("a_second_read_would_answer_this_instead")
  end
end

RSpec.describe "a lifecycle" do
  def boot_wire
    registry = Hecks::Runtime::Registry.new

    Hecks.with_registry(registry) do
      Kernel.load(InMemoryDomain::PERSISTENCE_PORT)
      Kernel.load(InMemoryDomain::EXTRACTION_PORT)
      Kernel.load(InMemoryDomain::MEMORY_ADAPTER)
      Kernel.load(InMemoryDomain::PRISM_ADAPTER)
      Kernel.load(WIRE_BLUEBOOK)
      Hecks::Runtime::Loader.bind_runtime(
        Hecks::Runtime::Dispatcher.new(registry)
      )
    end
  end

  it "is born at its default — the field exists before any transition" do
    runtime = boot_wire
    runtime.dispatch_flat("Wire::Drawer.Open", number: { value: "d" })

    expect(Wire::Drawer.find("d").status).to eq("open")
  end

  it "applies the transition the command names" do
    runtime = boot_wire
    runtime.dispatch_flat("Wire::Drawer.Open", number: { value: "d" })
    runtime.dispatch_flat("Wire::Drawer.Shut", number: { value: "d" })

    expect(Wire::Drawer.find("d").status).to eq("shut")
  end

  it "refuses a move the machine does not admit, in so many words" do
    runtime = boot_wire
    runtime.dispatch_flat("Wire::Drawer.Open", number: { value: "d" })
    runtime.dispatch_flat("Wire::Drawer.Shut", number: { value: "d" })

    expect { runtime.dispatch_flat("Wire::Drawer.Shut", number: { value: "d" }) }
      .to raise_error(Hecks::Runtime::LifecycleRefused,
                      'Shut refused — status is "shut", and Shut moves it only from "open"')
  end

  it "addresses a record by its reference key, like every saga leg must" do
    runtime = boot_wire
    # a wire between drawers that were never opened is refused
    runtime.dispatch_flat("Wire::Drawer.Open", number: { value: "a" })
    runtime.dispatch_flat("Wire::Drawer.Open", number: { value: "b" })
    runtime.dispatch_flat("Wire::Wire.Ask", reference: { value: "w" }, amount: { cents: 1 }, source: "a", destination: "b")

    # The message names the declared path ("reference.value"), as identity_reading does everywhere.
    expect { runtime.dispatch_flat("Wire::Wire.Returned", wire: "missing") }
      .to raise_error(Hecks::Runtime::NotFound, /no Wire with reference\.value "missing"/)
  end
end
