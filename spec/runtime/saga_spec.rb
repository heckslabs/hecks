require "spec_helper"

WIRE_BLUEBOOK = File.join(InMemoryDomain::ROOT, "spec/fixtures/settlement.bluebook")

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

  # `begin_saga` used to seed a fresh instance's own memory with the
  # starting event's own `.payload` directly — the SAME Hash object, not a
  # copy. A `remember` written mid-saga (or any other future write into
  # `instance[:memory]`) would then be, silently, ALSO a write into an
  # event that had already happened and been logged — retroactively
  # adding a field nothing announced. `.dup` on the way in breaks the
  # alias without changing what the saga's own memory actually holds.
  it "seeds a fresh saga's own memory as a COPY of the starting event's payload, never the same object" do
    runtime = funded
    # A refused leg unwinds rather than ending (see the example above),
    # so this instance survives long enough to inspect directly — a wire
    # that lands cleanly ends immediately and is reaped from
    # `saga_instances` before there is anything left to check.
    runtime.dispatch("Wire::Drawer.Shut", number: { value: "right" })
    result = runtime.dispatch("Wire::Wire.Ask",
                              reference: { value: "wire-2" }, amount: { cents: 1_000 },
                              source: "left", destination: "right")

    started  = result.events.find { |event| event.name == "WireAsked" }
    instance = runtime.registry.saga_instances["Carry"]["wire-2"]

    expect(instance[:memory]).not_to equal(started.payload)
    expect(instance[:memory]).to eq(started.payload)
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
  # One instrumented dispatch, several facts about its SAME outcome
  # (the stderr message, bounded retry count, saga log entries, final
  # states of both the wire and the money) — all following from one
  # crashing leg, which splitting would force re-triggering repeatedly.
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
      result = runtime.dispatch("Wire::Wire.Ask",
                                reference: { value: "wire-defect" }, amount: { cents: 500 },
                                source: "left", destination: "right")
    end.to output(/Carry.*wire-defect.*Drawer\.Take.*after 4 attempts.*boom/m).to_stderr

    expect(result.events.map(&:name)).to eq(["WireAsked"])
    expect(Wire::Wire.find("wire-defect").status).to eq("asked")

    # Every attempt actually ran — bounded retry, not a single shot before
    # giving up.
    expect(attempts).to eq(Hecks::Runtime::SagaInterpreter::MAX_DEFECT_RETRIES + 1)

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
      if verb == "Wire::Drawer.Put" && args[:to] == "right"
        attempts += 1
        raise NoMethodError, "undefined method `boom' for nil"
      end

      real_reenter.call(verb, **args)
    end

    expect do
      runtime.dispatch("Wire::Wire.Ask",
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

  # M22 — a logged advance's own `from:`/`to:` used to be re-derived from
  # `handler.from_state`/`handler.to_state` A SECOND TIME, after the real
  # mutation already happened — the SAME handler object `Properties.
  # saga_advances_follow_declared_handlers` (fuzzing/properties.rb) walks
  # to build its own "declared edges" list, so the logged pair could never
  # disagree with that list no matter what the runtime actually stored: it
  # was the identical fact, read twice. This intercepts `handler_for` to
  # make that second read answer something ELSE ("a_second_read_would_
  # answer_this_instead") from the FIRST read's own real, correct value
  # ("asked", the declared self-loop `"WireAsked" => "asked", from:
  # "asked"`) — the shape of bug this fix closes: any future defect that
  # divides "what got stored" from "what the handler says" now surfaces in
  # the log immediately, because the log is read back FROM the instance,
  # never from a second call to the handler.
  #
  # `to_state_calls` proves the mechanism directly: the fixed interpreter
  # calls `handler.to_state` exactly ONCE (to perform the mutation) and
  # never again to build the log entry — the old code's own two-calls
  # shape is exactly the coupling this test would catch.
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
    pm.define_singleton_method(:handler_for) do |event|
      event == "WireAsked" ? stub_handler : real_handler_for.call(event)
    end

    runtime.dispatch("Wire::Wire.Ask",
                     reference: { value: "wire-log-fidelity" }, amount: { cents: 500 },
                     source: "left", destination: "right")

    entry = runtime.sagas.find { |s| s[:process_manager] == "Carry" && s[:on] == "WireAsked" && s[:advanced] }

    # The handler's own `to_state` was consulted exactly once — for the
    # real mutation — never again to build the log entry.
    expect(to_state_calls).to eq(1)
    # So the log carries the value the instance was ACTUALLY moved to
    # (the first, real read)…
    expect(entry[:to]).to eq(real_to_state)
    # …never a second, different read of the same handler — the shape of
    # bug that made the property this feeds unable to ever fail.
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
      .to raise_error(Hecks::Runtime::LifecycleRefused,
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
      .to raise_error(Hecks::Runtime::NotFound, /no Wire with reference\.value "missing"/)
  end
end
