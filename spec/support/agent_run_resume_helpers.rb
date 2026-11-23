require "fileutils"
require "json"
require "tmpdir"

# The stand-in `claude` and the launcher calls behind spec/agent_run_resumed_session_spec.rb: a
# listing of one session, a resume that backgrounds it, and the dispatch, check and resume of a run.
module AgentRunResumeHelpers
  STAND_IN = <<~SH.freeze
    #!/bin/sh
    here=$(dirname "$0")
    if [ "$1" = "agents" ]; then cat "$here/sessions.json"; exit 0; fi
    printf 'backgrounded · stand-in-session\\n'
  SH

  # Gives the group a scratch directory holding the stand-in `claude`, first on the search path.
  def self.included(group)
    group.let(:scratch) { File.realpath(Dir.mktmpdir("agent-resume")) }
    group.around { |example| with_stand_in { example.run } }
    group.before { settle_instantly }
  end

  def with_stand_in
    env = ENV.to_h.slice("PATH", "HOME")
    install_stand_in
    ENV["PATH"] = "#{scratch}:#{env["PATH"]}"
    ENV["HOME"] = scratch
    yield
  ensure
    ENV.update(env)
    FileUtils.rm_rf(scratch)
  end

  def install_stand_in
    File.write(File.join(scratch, "claude"), STAND_IN)
    File.chmod(0o755, File.join(scratch, "claude"))
  end

  def settle_instantly
    allow(Hecks::Adapters::ClaudeAgents).to(receive(:new).and_wrap_original do |original, **context|
      original.call(**context, settings: { jobs: File.join(scratch, "jobs"), settle: 0 })
    end)
  end

  def launch(*argv) = Hecks::Adapters::Driving::CliRunner.call(runtime: @hecks, argv: argv, program: "hecks")

  # Lists one session, `id` for both its short and full id, in `state`.
  def sessions(state, id: "stand-in-session")
    File.write(File.join(scratch, "sessions.json"), JSON.generate([{ id: id, state: state }]))
    FileUtils.mkdir_p(File.join(scratch, "jobs", id))
    File.write(File.join(scratch, "jobs", id, "state.json"), JSON.generate(state: state))
  end

  def finished_run(run)
    launch("agent_run.dispatch!", "run.value=#{run}", "repo.value=#{scratch}", "brief.value=say ok", "--wait")
    sessions("working")
    launch("agent_run.check!", "to=#{run}", "--wait")
    sessions("done")
    launch("agent_run.check!", "to=#{run}", "--wait")
  end

  def started?(run) = launch("agent_run.started_of_run", "run.value=#{run}").to_s.include?(run)

  def resume(session) = launch("fleet.resume!", "session.value=#{session}", "name.value=again", "--wait")
end
