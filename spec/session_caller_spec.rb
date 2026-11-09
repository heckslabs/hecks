require "spec_helper"
require "hecks/hecks/adapters/session_caller"

# A started session names itself in its environment, so the usage log says which run ran each
# launcher line. The name is the role and the run, kept to safe characters and 64 of them.
RSpec.describe Hecks::Adapters::SessionCaller do
  let(:base) { { "CARGO_TARGET_DIR" => "/shared" } }

  it "adds the role and run to the session's environment", :aggregate_failures do
    env = described_class.environment(base, { agent: { value: "coder" }, run: { value: "fix-it" } })
    expect(env).to include("HECKS_CALLER" => "coder:fix-it", "CARGO_TARGET_DIR" => "/shared")
  end

  it "names the run alone when no role is named" do
    expect(described_class.name({ run: "fix-it" })).to eq("fix-it")
  end

  it "adds nothing when the record names neither" do
    expect(described_class.environment(base, {})).to eq(base)
  end

  it "keeps to 64 safe characters", :aggregate_failures do
    name = described_class.name({ agent: "coder", run: "a b$c#{"x" * 80}" })
    expect(name.length).to eq(64)
    expect(name).not_to match(/[ $]/)
  end
end
