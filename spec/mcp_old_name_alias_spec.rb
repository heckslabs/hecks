require "spec_helper"
require "hecks/adapters/driving/mcp"

# An agent that asks the door for a command by a name the bluebook renamed gets the new command:
# the door resolves names through the same projection the launcher uses (ADR 0163, step 67).
RSpec.describe "MCP door resolves old command names" do
  let(:domain) { File.expand_path("lib/hecks/hecks", Dir.pwd) }
  let(:runtime) { Hecks::Adapters::Driving::Mcp.boot(domain) }

  it "resolves push_train.push to the renamed send command" do
    expect(Hecks::Storehouse.verbs_for(runtime, ["push_train.push"]).first).to end_with("SendTrain.Send")
  end

  it "resolves pull_request.merge to the renamed take command" do
    expect(Hecks::Storehouse.verbs_for(runtime, ["pull_request.merge"]).first).to end_with("ReviewRequest.Take")
  end

  it "refuses an unknown name" do
    expect(Hecks::Storehouse.verbs_for(runtime, ["no_such.thing"]).first).to be_nil
  end
end
