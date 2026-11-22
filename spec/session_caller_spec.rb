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

  it "exports the run, role and work item a commit's trailers name", :aggregate_failures do
    held = { agent: { value: "coder" }, run: { value: "fix-it" }, work: { value: "the-item" } }
    expect(described_class.environment(base, held)).to include(
      "HECKS_RUN_KEY" => "fix-it", "HECKS_ROLE" => "coder", "HECKS_WORK" => "the-item"
    )
  end

  it "exports no run, role or work for a caller that names none", :aggregate_failures do
    env = described_class.environment(base, {})
    expect(env.keys).not_to include("HECKS_RUN_KEY", "HECKS_ROLE", "HECKS_WORK")
  end

  it "exports only what the record names" do
    env = described_class.environment(base, { run: "fix-it" })
    expect(env.keys).not_to include("HECKS_ROLE", "HECKS_WORK")
  end
end
