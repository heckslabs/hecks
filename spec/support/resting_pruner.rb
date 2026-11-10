require_relative "stand_in_claude"

# The helpers the pruning examples share: the CLI, the reaction log, a run's dispatch and finish,
# and the pruner put back to rest between examples.
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

  # A landing of a Work item: the item is planned, a Landing is recorded (refused, since the
  # scratch checkout holds no repository), and the LandedWork port answers LandedWorkFound for it.
  def land(work)
    launch("tickets", "Work.plan!", "work.value=#{work}", "title.value=#{work}", "--wait")
    launch("Landing.land!", "run.value=#{work}", "checkout.value=#{scratch}", "branch.value=#{work}", "--confirm", "--wait")
    launch("Landing.find_landed_work!", "to=#{work}", "branch.value=#{work}", "--wait")
  end

  def pruners_started = reactions("StartThePrunerWhenWoken").size

  def rest_the_pruner
    launch("pruning.seat!", "role.value=pruner", "--wait")
    launch("pruning.rest!", "to=pruner", "--wait")
    @hecks.registry.reaction_log.clear
  end
end

# A stand-in `claude` and a scratch directory hold the sessions and the journal, so no real
# session starts and none of the owner's state is touched.
RSpec.shared_context "with a resting pruner" do
  include_context "with a stand-in claude"
  include PruningSpecHelpers

  before(:all) do
    @hecks = boot_hecks_in_memory
  end

  before { rest_the_pruner }
end
