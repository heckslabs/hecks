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
      Hecks::Runtime::Loader.bind_runtime(Hecks::Runtime::Dispatcher.new(registry))
    end
  end

  def funded(runtime = boot_wire)
    runtime.dispatch_flat("Wire::Drawer.Open", number: { value: "left" })
    runtime.dispatch_flat("Wire::Drawer.Open", number: { value: "right" })
    runtime.dispatch_flat("Wire::Drawer.Put",  number: { value: "left" }, amount: { cents: 10_000 })
    runtime
  end

  def funded_with_shut_right
    runtime = funded
    runtime.dispatch_flat("Wire::Drawer.Shut", number: { value: "right" })
    runtime
  end

  def ask(runtime, reference, cents)
    runtime.dispatch_flat("Wire::Wire.Ask",
                          reference: { value: reference }, amount: { cents: cents }, source: "left", destination: "right")
  end

  def landed_wire
    runtime = funded
    ask(runtime, "wire-1", 2_500)
    runtime
  end

  def left_cents = Wire::Drawer.find("left").cents.to_h

  def carry_instance(runtime, reference) = runtime.registry.saga_instances["Carry"][reference]

  def starting_event(result) = result.events.find { |event| event.name == "WireAsked" }

  # Asks for a wire while expecting the saga's defect warning on STDERR; answers the dispatch result.
  def ask_reporting(runtime, reference, cents, warning)
    result = nil
    expect { result = ask(runtime, reference, cents) }.to output(warning).to_stderr
    result
  end

  # Replaces `reenter` so a leg the block selects raises a defect; answers the log of attempts.
  def crash_leg(runtime, &selects)
    real_reenter = runtime.method(:reenter)
    attempts = []
    runtime.define_singleton_method(:reenter) do |verb, **args|
      if selects.call(verb, args)
        attempts << verb
        raise NoMethodError, "undefined method `boom' for nil"
      end

      real_reenter.call(verb, **args)
    end
    attempts
  end

  # A defect in the first leg (Drawer.Take) must not fail Ask's own dispatch, which has
  # already persisted WireAsked. `reenter` is overridden on this runtime, as in policy_spec.
  # Nothing was taken, so the compensating leg has nothing to put back.
  def run_with_crashing_take
    runtime = funded
    attempts = crash_leg(runtime) { |verb, _args| verb == "Wire::Drawer.Take" }
    result = ask_reporting(runtime, "wire-defect", 500, /Carry.*wire-defect.*Drawer\.Take.*after 4 attempts.*boom/m)
    [runtime, attempts, result]
  end

  # The crash lands on the second leg, after Take moved real money out of "left";
  # once retries are exhausted, `unwind` runs the same compensating leg a refusal would.
  def run_with_crashing_put
    runtime = funded
    attempts = crash_leg(runtime) { |verb, args| verb == "Wire::Drawer.Put" && args[:to] == "right" }
    ask_reporting(runtime, "wire-crash", 1_000, /Carry.*wire-crash.*Drawer\.Put.*after 4 attempts.*boom/m)
    [runtime, attempts]
  end

  # The depth ceiling unwinds on the first hit, with no retry. Stubbed so only the third
  # check (the credit leg's Drawer.Put) trips: Take really runs, so there is money to put back.
  def run_to_reaction_ceiling
    runtime = funded
    checks = 0
    runtime.define_singleton_method(:reaction_depth_reached?) do
      checks += 1
      checks == 3
    end
    ask(runtime, "wire-ceiling", 1_000)
    runtime
  end

  def put_refusal = hash_including(dispatch: "Drawer.Put", delivered: false, reason: "Put refused — the drawer is open")

  def ceiling_refusal
    hash_including(process_manager: "Carry", instance: "wire-ceiling", dispatch: "Drawer.Put",
                   delivered: false, reason: "reaction depth 5 reached")
  end

  def uncompensated_refusal = hash_including(on: "refused", advanced: false, reason: 'in "asked", not "carrying"')

  def compensated_defect(instance, dispatch)
    hash_including(process_manager: "Carry", instance: instance, dispatch: dispatch,
                   delivered: false, defect: true, defect_compensated: true, error_class: "NoMethodError")
  end

  def wire_asked_advance(runtime)
    runtime.sagas.find { |s| s[:process_manager] == "Carry" && s[:on] == "WireAsked" && s[:advanced] }
  end

  def carry_manager(runtime) = runtime.registry.bluebook("Wire").process_managers.find { |pm| pm.name == "Carry" }

  # A stand-in for the WireAsked handler that logs each `to_state` read in `reads` and answers
  # differently on a second read.
  def handler_stub(real_handler, reads)
    real_to_state = real_handler.to_state
    stub = Struct.new(:event_type, :from_state, :dispatches)
                 .new(real_handler.event_type, real_handler.from_state, real_handler.dispatches)
    stub.define_singleton_method(:to_state) do
      reads << true
      reads.size == 1 ? real_to_state : "a_second_read_would_answer_this_instead"
    end
    stub
  end

  # Swaps the Carry manager's WireAsked handler for a counting stand-in; answers the read log.
  def count_to_state_reads(runtime)
    pm = carry_manager(runtime)
    reads = []
    stub_handler = handler_stub(pm.handler_for("WireAsked"), reads)
    real_handler_for = pm.method(:handler_for)
    pm.define_singleton_method(:handler_for) do |event, state = nil|
      event == "WireAsked" ? stub_handler : real_handler_for.call(event, state)
    end
    reads
  end

  it "carries a wire end to end — exact cents, exact states", :aggregate_failures do
    landed_wire

    expect(Wire::Drawer.find("left").cents.to_h).to  eq(cents: 7_500)
    expect(Wire::Drawer.find("right").cents.to_h).to eq(cents: 2_500)
    expect(Wire::Wire.find("wire-1").status).to eq("landed")
  end

  it "retires the saga once the wire has landed", :aggregate_failures do
    runtime = landed_wire

    expect(runtime.sagas.select { |s| s[:ended] }).to contain_exactly(
      hash_including(process_manager: "Carry", instance: "wire-1", ended: true)
    )
    expect(runtime.registry.saga_instances["Carry"]).to be_empty
  end

  it "remembers the opening payload — the credit leg reads a destination no event carried" do
    ask(funded, "wire-1", 100)

    expect(Wire::Drawer.find("right").cents.to_h).to eq(cents: 100)
  end

  # No manual compensation: asserting the money is back must not depend on the test
  # putting it back by hand.
  it "unwinds a refused leg on its own, without anyone noticing", :aggregate_failures do
    runtime = funded_with_shut_right
    ask(runtime, "wire-2", 1_000)

    expect(runtime.sagas).to include(put_refusal)
    expect(left_cents).to eq(cents: 10_000)
    expect(Wire::Wire.find("wire-2").status).to eq("returned")
  end

  # Without `.dup`, a `remember` mid-saga would also write into the logged starting event.
  it "seeds a fresh saga's own memory as a COPY of the starting event's payload, never the same object", :aggregate_failures do
    # A refused leg unwinds rather than ending, so the instance survives to be inspected;
    # a clean landing is reaped from saga_instances at once.
    runtime = funded_with_shut_right
    result = ask(runtime, "wire-2", 1_000)
    memory = carry_instance(runtime, "wire-2")[:memory]

    expect(memory).not_to equal(starting_event(result).payload)
    expect(memory).to eq(starting_event(result).payload)
  end

  it "ignores an uncorrelated event — a manual Take is just a take", :aggregate_failures do
    runtime = funded
    runtime.dispatch_flat("Wire::Drawer.Take", number: { value: "left" }, amount: { cents: 500 })

    expect(runtime.sagas).to be_empty
    expect(left_cents).to eq(cents: 9_500)
  end

  describe "a crashing first leg" do
    it "is retried MAX_DEFECT_RETRIES times, then given up" do
      _runtime, attempts, = run_with_crashing_take

      expect(attempts.size).to eq(Hecks::Runtime::SagaInterpreter::MAX_DEFECT_RETRIES + 1)
    end

    it "does not fail the Ask that already persisted WireAsked", :aggregate_failures do
      _runtime, _attempts, result = run_with_crashing_take

      expect(result.events.map(&:name)).to eq(["WireAsked"])
      expect(Wire::Wire.find("wire-defect").status).to eq("asked")
    end

    it "has nothing to undo, so no money moves" do
      run_with_crashing_take

      expect(left_cents).to eq(cents: 10_000)
    end

    it "logs the retries and the defect it gave up on", :aggregate_failures do
      runtime, = run_with_crashing_take
      take_log = runtime.sagas.select { |s| s[:dispatch] == "Drawer.Take" }

      expect(take_log.count { |s| s[:retrying] }).to eq(3)
      expect(take_log.last).to include(delivered: false, defect: true, defect_compensated: true, error_class: "NoMethodError")
    end

    # Compensation is attempted, but the instance is still in "asked" and the compensating
    # leg is declared from "carrying", so nothing is put back.
    it "attempts compensation from a state that cannot undo anything", :aggregate_failures do
      runtime, = run_with_crashing_take

      expect(runtime.sagas).to include(uncompensated_refusal)
      expect(carry_instance(runtime, "wire-defect")[:state]).to eq("asked")
    end
  end

  describe "a crashing second leg" do
    it "is retried, then compensated for real once retries are exhausted", :aggregate_failures do
      runtime, attempts = run_with_crashing_put

      expect(attempts.size).to eq(Hecks::Runtime::SagaInterpreter::MAX_DEFECT_RETRIES + 1)
      expect(left_cents).to eq(cents: 10_000)
      expect(runtime.sagas).to include(compensated_defect("wire-crash", "Drawer.Put"))
    end

    it "returns the wire", :aggregate_failures do
      runtime, = run_with_crashing_put

      expect(Wire::Wire.find("wire-crash").status).to eq("returned")
      expect(carry_instance(runtime, "wire-crash")[:state]).to eq("returned")
    end
  end

  it "unwinds when the reaction-depth ceiling is hit, not just when the domain refuses", :aggregate_failures do
    runtime = run_to_reaction_ceiling

    expect(runtime.sagas).to include(ceiling_refusal)
    expect(left_cents).to eq(cents: 10_000)
    expect(Wire::Wire.find("wire-ceiling").status).to eq("returned")
  end

  it "records an event that arrives in the wrong phase, and does not advance" do
    runtime = funded_with_shut_right
    ask(runtime, "wire-3", 100)
    # The unwind's own Put emits PutIn while the procedure sits in "returned".

    expect(runtime.sagas).to include(hash_including(on: "PutIn", advanced: false, reason: 'in "returned", not "carrying"'))
  end

  # The log must come from the stored instance, not a second read of the handler, or
  # Properties.saga_advances_follow_declared_handlers could never fail. The stub answers
  # differently on a second `to_state` call; `reads` pins that it is read once.
  it "logs the saga instance's own real transition, not a second read of the handler that decided it", :aggregate_failures do
    runtime = funded
    real_to_state = carry_manager(runtime).handler_for("WireAsked").to_state
    reads = count_to_state_reads(runtime)
    ask(runtime, "wire-log-fidelity", 500)

    expect([reads.size, wire_asked_advance(runtime)[:to]]).to eq([1, real_to_state])
  end
end
