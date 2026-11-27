require "spec_helper"
require "hecks/adapters/driving/mcp"

# The door resolves a command name through the same projection the launcher uses (ADR 0163, step
# 67), so a command renamed before 8.0 answers to its current name only: the old spelling is
# unknown at the door as at the launcher.
RSpec.describe "MCP door resolves command names as the launcher does" do
  let(:domain) { File.expand_path("lib/hecks/hecks", Dir.pwd) }
  let(:runtime) { Hecks::Adapters::Driving::Mcp.boot(domain) }

  def verb(name) = Hecks::Storehouse.verbs_for(runtime, [name]).first

  it("resolves send_train.send to the send command") { expect(verb("send_train.send")).to end_with("SendTrain.Send") }

  it("resolves review_request.take to the take command") { expect(verb("review_request.take")).to end_with("ReviewRequest.Take") }

  it("resolves the old spelling push_train.push to nothing") { expect(verb("push_train.push")).to be_nil }

  it("resolves the old spelling pull_request.merge to nothing") { expect(verb("pull_request.merge")).to be_nil }

  it("refuses an unknown name") { expect(verb("no_such.thing")).to be_nil }
end
