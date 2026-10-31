require "spec_helper"

RSpec.describe "a saga that faults" do
  let(:leg_class) { Hecks::Runtime::SagaInterpreter::Leg }
  let(:handler)   { Struct.new(:to_state).new("needs_human") }

  def taken(state:, to: "needs_human", memory: {})
    instance = { state: state, memory: memory }
    leg_class.new(nil, nil, nil, nil, nil, instance, nil, nil).tap { |leg| leg.take(Struct.new(:to_state).new(to)) }.instance
  end

  it "records the stage it faulted from" do
    expect(taken(state: "gated")[:memory][Hecks::Runtime::SagaInterpreter::FAULTED_FROM_KEY]).to eq("gated")
  end

  it "records nothing for a move that is not a fault" do
    expect(taken(state: "gated", to: "landing")[:memory]).to eq({})
  end
end
