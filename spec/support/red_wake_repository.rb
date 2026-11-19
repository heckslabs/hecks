# frozen_string_literal: true

require "json"
require "open3"
require "time"
require "hecks/hecks/adapters/red_flag_marker"

# A scratch repository for the red-main wake specs, under the stand-in claude's `scratch`: its
# red flag, a linked worktree of it, wakes raised against the booted Hecks domain, and the runs
# keyed `red-wake-`. Mixed into a group that includes the "with a stand-in claude" context.
module RedWakeRepository
  def repo = File.join(scratch, "main")

  def open_repository
    git("init", "-q", "-b", "main", repo, chdir: scratch)
    git("commit", "-q", "--allow-empty", "-m", "start")
  end

  def git(*, chdir: repo)
    out, status = Open3.capture2e("git", "-c", "user.name=t", "-c", "user.email=t@t", *, chdir: chdir)
    raise out unless status.success?

    out
  end

  # Raises the scratch flag for a commit. The domain is booted once per group, so each example
  # raises its own flag.
  #
  # @param commit [String] the red commit, whose first ten characters name the flag
  # @return [String] the run a session for the flag takes: `red-wake-flag-<commit[0, 10]>`
  def flag!(commit)
    Hecks::Adapters::RedFlagMarker.new(File.join(repo, ".git")).raise!(commit: commit, run: {})
    "red-wake-flag-#{commit[0, 10]}"
  end

  def launch(*argv) = Hecks::Adapters::Driving::CliRunner.call(runtime: @hecks, argv: argv, program: "hecks")

  def wake(episode, at: repo)
    launch("agents", "Escalation.raise!", "escalation.value=#{episode}", "event.value=EpisodeParked",
           "rule.value=all-hands-on-red", "role.value=orchestrator", "repo.value=#{at}", "brief.value=report", "--wait")
  end

  # @param episodes [Array<String>] the episodes whose runs are read
  # @return [Array<Hash>] the `red-wake-` runs whose work is one of them
  def red_runs(*episodes)
    store = @hecks.registry.repository("Hecks", @hecks.registry.bluebook("Hecks").aggregate("AgentRun"))
    store.all.map { |run| Hecks::Runtime::Value.materialize(run.state) }
         .select { |run| run.dig(:run, :value).to_s.start_with?("red-wake-") && episodes.include?(run.dig(:work, :value)) }
  end

  # The stand-in session's job reads blocked on a question.
  def block_the_session
    File.write(File.join(scratch, "jobs", "stand-in-session", "state.json"),
               JSON.generate(state: "blocked", detail: "which sha?", updatedAt: Time.now.utc.iso8601(3)))
  end
end
