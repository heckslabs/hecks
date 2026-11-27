require "spec_helper"
require "hecks/adapters/driving/mcp"

# An agent that asks the door for a command by a name the bluebook renamed gets the new command:
# the door resolves names through the same projection the launcher uses (ADR 0163, step 67). The
# Hecks world renames nothing now, so the launcher setting here carries one rename of its own.
RSpec.describe "MCP door resolves old command names" do
  let(:domain) { File.expand_path("lib/hecks/hecks", Dir.pwd) }
  let(:runtime) { Hecks::Adapters::Driving::Mcp.boot(domain) }
  let(:options) { Hecks::Adapters::Driving::LauncherOptions }

  before do
    settings = options.settings(runtime, "Hecks")
    renamed = settings.merge(renamed: { "model_check.run" => "model_check_run.model_check" })
    allow(options).to receive(:settings).and_call_original
    allow(options).to receive(:settings).with(runtime, "Hecks").and_return(renamed)
  end

  it "resolves an old name to the command it became" do
    expect(Hecks::Storehouse.verbs_for(runtime, ["model_check.run"]).first).to end_with("ModelCheckRun.ModelCheck")
  end

  it "refuses an unknown name" do
    expect(Hecks::Storehouse.verbs_for(runtime, ["no_such.thing"]).first).to be_nil
  end
end
