require "spec_helper"

RSpec.describe "resuming a faulted saga" do
  let(:store)       { Struct.new(:saved) { def save_saga(**opts) = saved << opts }.new([]) }
  let(:blueprint)   { Struct.new(:process_managers).new([Struct.new(:name).new("GateAndBoard")]) }
  let(:registry) do
    Struct.new(:saga_instances, :saga_mutex, :blueprint, :store) do
      def bluebook(_domain) = blueprint
      def saga_persistence(_domain, _process_manager = nil) = store
    end.new(Hash.new { |h, k| h[k] = {} }, Mutex.new, blueprint, store)
  end
  let(:interpreter) { Hecks::Runtime::SagaInterpreter.new(registry, dispatcher: nil) }
  let(:args)        { { run: "r1", branch: "feature", checkout: "/w", confirm: true } }

  def fault_at(stage)
    registry.saga_instances["GateAndBoard"]["r1"] = { state: "needs_human", memory: args.merge(Hecks::Runtime::SagaInterpreter::FAULTED_FROM_KEY => stage) }
  end

  it "puts the instance back in the stage it faulted from" do
    fault_at("gated")
    expect(interpreter.resume("hecks", "GateAndBoard", "r1")).to include(resumed: true, stage: "gated")
  end

  it "hands back the arguments the saga started with" do
    fault_at("gated")
    expect(interpreter.resume("hecks", "GateAndBoard", "r1")[:arguments]).to include(branch: "feature", run: "r1")
  end

  it "refuses an instance that is not waiting for a human" do
    registry.saga_instances["GateAndBoard"]["r1"] = { state: "landing", memory: args }
    expect(interpreter.resume("hecks", "GateAndBoard", "r1")).to include(resumed: false)
  end
end
