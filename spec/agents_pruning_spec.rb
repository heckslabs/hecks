require "spec_helper"
require_relative "support/stand_in_claude"

# The helpers the pruning examples share: the CLI, the reaction log and a run's dispatch and finish.
module PruningSpecHelpers
  def launch(*argv) = Hecks::Adapters::Driving::CliRunner.call(runtime: @hecks, argv: argv, program: "hecks")

  def reactions(policy) = @hecks.registry.reaction_log.select { |r| r[:policy] == policy && r[:delivered] }

  def dispatch(run)
    launch("agent_run.dispatch!", "run.value=#{run}", "repo.value=#{scratch}", "brief.value=work",
           "agent.value=coder", "--wait")
  end

  def finish(run)
    File.write(File.join(scratch, "jobs", "stand-in-session", "state.json"), JSON.generate(state: "done"))
    launch("agent_run.check!", "to=#{run}", "--wait")
  end
end

# A finished run wakes the pruner, which starts a session through AgentRun. A stand-in `claude`
# and a scratch directory hold the sessions and the journal, so no real session starts and none of
# the owner's state is touched.
RSpec.describe "the pruner started by a finished run" do
  include_context "with a stand-in claude"
  include PruningSpecHelpers

  before(:all) do
    @hecks = Hecks.boot(File.join(InMemoryDomain::ROOT, "lib/hecks/hecks"), install_driving: false)
  end

  before do
    launch("pruning.seat!", "role.value=pruner", "--wait")
    launch("pruning.rest!", "to=pruner", "--wait")
    @hecks.registry.reaction_log.clear
  end

  it "dispatches the pruner once when a run finishes" do
    dispatch("w-finished")
    finish("w-finished")
    expect(reactions("DispatchThePrunerWhenWoken").size).to eq(1)
  end

  it "wakes the pruner only for the finished run, not for its own finish", :aggregate_failures do
    dispatch("w-own")
    finish("w-own")
    expect(reactions("WakeThePrunerWhenARunFinishes").size).to eq(1)
    expect(reactions("RestThePrunerWhenItsRunEnds").size).to eq(1)
  end

  it "starts no second pruner while one is working" do
    launch("pruning.seat!", "role.value=pruner", "--wait")
    launch("pruning.wake!", "to=pruner", "repo.value=#{scratch}", "brief.value=prune", "--wait")
    dispatch("w-second")
    finish("w-second")
    expect(reactions("DispatchThePrunerWhenWoken").size).to eq(1)
  end
end
