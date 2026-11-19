require "spec_helper"
require "hecks/hecks/adapters/pinned_role_holders"
require "hecks/hecks/adapters/claude_session_listing"

# The facts `AgentRun` judges a pinned role's second session on: which other live session holds
# the run's role, by a started run bound to it or by its listed name. The listing and the runs
# are stand-ins.
RSpec.describe Hecks::Adapters::PinnedRoleHolders do
  def holders(entries, runs: [])
    listing = instance_double(Hecks::Adapters::ClaudeSessionListing, entries: entries)
    described_class.new(listing: listing, runs: -> { runs }, pinned: -> { ["orchestrator"] })
  end

  def entry(id, name, state, status: nil)
    { "id" => id, "sessionId" => "#{id}-full", "name" => name, "state" => state, "status" => status }
  end

  def orchestrator(session = "") = { agent: "", works_as: "orchestrator", session: session }

  it "names nothing for a run whose role no PinnedRole row names" do
    found = holders([entry("a", "coder", "working")]).call(works_as: "coder", session: "")

    expect(found).to eq(described_class::NONE)
  end

  it "names a live session listed under the role's name, in any case" do
    expect(holders([entry("a", "ORCHESTRATOR", "working")]).call(orchestrator)).to include(role_holder: "a")
  end

  it "names a session a started run of the role is bound to, whatever its name" do
    runs = [{ run: "r", status: "started", agent: "orchestrator", works_as: "", session: "b" }]

    expect(holders([entry("b", "fleet", "blocked")], runs: runs).call(orchestrator)).to include(role_holder: "b")
  end

  it "takes a run's part as its role, so an orchestrator agent working as answerer is not pinned", :aggregate_failures do
    runs = [{ run: "a", status: "started", agent: "orchestrator", works_as: "answerer", session: "b" }]
    found = holders([entry("b", "q-1", "working")], runs: runs)

    expect(found.call(agent: "orchestrator", works_as: "answerer", session: "")).to eq(described_class::NONE)
    expect(found.call(orchestrator)).to eq(described_class::NONE.merge(pinned_role: "orchestrator"))
  end

  it "counts a session listed busy as live, whatever its state" do
    expect(holders([entry("a", "orchestrator-2", "done", status: "busy")]).call(orchestrator)).to include(role_holder: "a")
  end

  it "leaves out the run's own session, an idle one and another role that begins with the name", :aggregate_failures do
    entries = [entry("own", "orchestrator", "working"), entry("idle", "orchestrator", "done", status: "idle"),
               entry("o", "orchestrator-owner", "working")]

    expect(holders(entries).call(orchestrator("own"))).to eq(described_class::NONE.merge(pinned_role: "orchestrator"))
  end
end
