require "spec_helper"
require_relative "support/stand_in_claude"

# A conflicting Work item asks the orchestrator for advice, and that event starts its session
# through AgentRun. A stand-in `claude` starts the session, so no real one runs: the spec shows the
# advice request becomes a run keyed by the routing request, and a check with no conflict starts
# nothing.
RSpec.describe "an advice request starting the orchestrator's session" do
  include_context "with a stand-in claude"

  before(:all) do
    @hecks = Hecks.boot(File.join(InMemoryDomain::ROOT, "lib/hecks/hecks"), install_driving: false)
  end

  def launch(*argv) = Hecks::Adapters::Driving::CliRunner.call(runtime: @hecks, argv: argv, program: "hecks")

  def check(work, conflict, hops: 1)
    launch("agents", "Routing.check!", "work.value=#{work}", "conflict.value=#{conflict}", "hops.value=#{hops}",
           "advice.value=advice-#{work}", "role.value=orchestrator", "repo.value=#{scratch}",
           "brief.value=Work item #{work} conflicts", "--wait").first.to_s
  end

  def running = launch("agent_run.running").first.to_s

  it "starts the orchestrator's run, keyed by the routing request", :aggregate_failures do
    check("w-conflict", "yes")
    expect(running).to include("advice-w-conflict")
    expect(running).to include("orchestrator")
  end

  it "starts no run for a Work item with no conflict" do
    check("w-clear", "no")
    expect(running).not_to include("advice-w-clear")
  end

  it "starts no run for a check at the hop limit", :aggregate_failures do
    expect(check("w-stop", "yes", hops: 3)).to include("under the hop limit")
    expect(running).not_to include("advice-w-stop")
  end
end
