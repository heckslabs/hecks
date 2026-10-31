require "spec_helper"

# A port operation may say which value of which command it handles (ADR 0163 step 50, grammar
# half). The word is admitted and carried in the IR; routing does not read it yet.
RSpec.describe "a port operation's handles" do
  def build_operation(&block)
    Hecks::Bluebook::DSL::PortOperationBuilder.build("BuildWasm", direction: :inbound) do
      emits "WasmBuilt"
      instance_eval(&block)
    end
  end

  it "records one command value per handles line" do
    op = build_operation { handles "Build.build!", value: "wasm" }
    expect(op.handles).to eq([{ command: "Build.build!", value: "wasm" }])
  end

  it "keeps several handled values in declared order" do
    op = build_operation do
      handles "Build.build!", value: "wasm"
      handles "Build.build!", value: "host"
    end
    expect(op.handles.map { |held| held[:value] }).to eq(%w[wasm host])
  end

  it "declares no handles when none are named" do
    op = build_operation { nil }
    expect(op.handles).to eq([])
  end
end
