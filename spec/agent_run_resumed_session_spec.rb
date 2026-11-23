require "spec_helper"
require "fileutils"
require "json"
require "tmpdir"

# `Fleet.resume!` through the booted Hecks domain: the AgentRun that holds the resumed session is
# recorded working again, so the tidy and the pruner no longer read it as finished. A session no
# run holds records nothing. A stand-in `claude` lists the session and takes the resume, so no
# real session is touched.
RSpec.describe "AgentRun follows a session Fleet.resume! woke" do
  RESUME_STAND_IN = <<~SH.freeze
    #!/bin/sh
    here=$(dirname "$0")
    if [ "$1" = "agents" ]; then cat "$here/sessions.json"; exit 0; fi
    printf 'backgrounded · stand-in-session\\n'
  SH

  before(:all) { @hecks = boot_hecks_in_memory }

  let(:scratch) { File.realpath(Dir.mktmpdir("agent-resume")) }

  around do |example|
    env = ENV.to_h.slice("PATH", "HOME")
    File.write(File.join(scratch, "claude"), RESUME_STAND_IN)
    File.chmod(0o755, File.join(scratch, "claude"))
    ENV["PATH"] = "#{scratch}:#{env["PATH"]}"
    ENV["HOME"] = scratch
    example.run
  ensure
    ENV.update(env)
    FileUtils.rm_rf(scratch)
  end

  before do
    allow(Hecks::Adapters::ClaudeAgents).to(receive(:new).and_wrap_original do |original, **context|
      original.call(**context, settings: { jobs: File.join(scratch, "jobs"), settle: 0 })
    end)
  end

  def launch(*argv) = Hecks::Adapters::Driving::CliRunner.call(runtime: @hecks, argv: argv, program: "hecks")

  def sessions(state)
    listed = { id: "stand-in-session", sessionId: "stand-in-session-0000-full", state: state }
    File.write(File.join(scratch, "sessions.json"), JSON.generate([listed]))
    job = File.join(scratch, "jobs", "stand-in-session")
    FileUtils.mkdir_p(job)
    File.write(File.join(job, "state.json"), JSON.generate(state: state))
  end

  def finished_run(run)
    launch("agent_run.dispatch!", "run.value=#{run}", "repo.value=#{scratch}", "brief.value=say ok", "--wait")
    sessions("working")
    launch("agent_run.check!", "to=#{run}", "--wait")
    sessions("done")
    launch("agent_run.check!", "to=#{run}", "--wait")
  end

  def started?(run) = launch("agent_run.started_of_run", "run.value=#{run}").to_s.include?(run)

  def resume = launch("fleet.resume!", "session.value=stand-in-session", "name.value=again", "--wait")

  it "records the finished run of a resumed session working again", :aggregate_failures do
    finished_run("resumed-one")
    sessions("working")
    expect(started?("resumed-one")).to be(false)
    resume

    expect(started?("resumed-one")).to be(true)
  end

  it "records nothing for a resumed session no run holds" do
    sessions("done")

    expect(resume.first.to_s).not_to include("AgentRunRevived")
  end
end
