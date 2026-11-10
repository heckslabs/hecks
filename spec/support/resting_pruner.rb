require_relative "stand_in_claude"

# The helpers the pruning examples share: the CLI, the reaction log, and a run's dispatch, finish
# and landing. Each example boots its own runtime, so it starts with no pruner and no reaction.
module PruningSpecHelpers
  def launch(*argv) = Hecks::Adapters::Driving::CliRunner.call(runtime: @hecks, argv: argv, program: "hecks")

  # A launch that must succeed: an unknown command or a refusal fails the example by name instead
  # of leaving the example to count on a step that never ran.
  def launch!(*argv)
    answer = launch(*argv)
    raise "`#{argv.first(2).join(" ")}` did not run: #{answer.first.to_s.lines.first}" unless answer.last.zero?

    answer
  end

  def reactions(policy) = @hecks.registry.reaction_log.select { |r| r[:policy] == policy && r[:delivered] }

  def dispatch(run)
    launch!("agent_run.dispatch!", "run.value=#{run}", "repo.value=#{scratch}", "brief.value=work",
            "agent.value=coder", "--wait")
  end

  def finish(run)
    File.write(File.join(scratch, "jobs", "stand-in-session", "state.json"), JSON.generate(state: "done"))
    launch!("agent_run.check!", "to=#{run}", "--wait")
  end

  # A landing of a Work item: the item is planned, a Landing is recorded (refused, since the
  # scratch checkout holds no repository), and the LandedWork port answers LandedWorkFound for it.
  # The last two answer non-zero by design: the landing is refused, and the find reports the
  # refusal of a Wake that the policy meets while a pruner works.
  def land(work)
    launch!("tickets", "Work.plan!", "work.value=#{work}", "title.value=#{work}", "--wait")
    launch("Landing.land!", "run.value=#{work}", "checkout.value=#{scratch}", "branch.value=#{work}", "--confirm", "--wait")
    launch("Landing.find_landed_work!", "to=#{work}", "branch.value=#{work}", "--wait")
  end

  def pruners_started = reactions("StartThePrunerWhenWoken").size
end

# A stand-in `claude` and a scratch directory hold the sessions and the journal, so no real
# session starts and none of the owner's state is touched.
RSpec.shared_context "with a resting pruner" do
  include_context "with a stand-in claude"
  include PruningSpecHelpers

  # Booted ahead of the stand-in's own hook, which stubs a class the boot loads.
  prepend_before { @hecks = boot_hecks_in_memory }
end
