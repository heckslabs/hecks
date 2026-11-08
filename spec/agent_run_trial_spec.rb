require "spec_helper"
require "fileutils"
require "json"
require "tmpdir"

# A trial run (key `live-*` or `resume-*`) retires itself once its session is read working or
# blocked. A stand-in `claude` is first on the search path, so no real session is listed or touched.
RSpec.describe "AgentRun trial runs through the Agents port" do
  TRIAL_STAND_IN = <<~SH.freeze
    #!/bin/sh
    here=$(dirname "$0")
    if [ "$1" = "agents" ]; then cat "$here/sessions.json"; exit 0; fi
    printf 'backgrounded · stand-in-session\\n'
  SH

  before(:all) do
    @hecks = boot_hecks_in_memory
  end

  let(:scratch) { File.realpath(Dir.mktmpdir("agent-trial")) }

  around do |example|
    env = ENV.to_h.slice("PATH", "HOME")
    install_stand_in
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

  def install_stand_in
    path = File.join(scratch, "claude")
    File.write(path, TRIAL_STAND_IN)
    File.chmod(0o755, path)
  end

  def listing(*entries) = File.write(File.join(scratch, "sessions.json"), JSON.generate(entries))

  def job(state)
    FileUtils.mkdir_p(File.join(scratch, "jobs", "stand-in-session"))
    File.write(File.join(scratch, "jobs", "stand-in-session", "state.json"), JSON.generate(state: state))
  end

  def launch(*argv) = Hecks::Adapters::Driving::CliRunner.call(runtime: @hecks, argv: argv, program: "hecks")

  def started_run(run)
    listing({ id: "stand-in-session", sessionId: "0000aaaa-1111", state: "working" })
    job("working")
    launch("agent_run.dispatch!", "run.value=#{run}", "repo.value=#{scratch}", "brief.value=say ok", "--wait")
  end

  def running?(run)
    started_run(run)
    launch("AgentRun.running").first.to_s.include?(run)
  end

  it "retires a live-* run whose session is working" do
    expect(running?("live-pid-1")).to be(false)
  end

  it "retires a resume-* run whose session is working" do
    expect(running?("resume-final-1")).to be(false)
  end

  it "keeps any other run started" do
    expect(running?("real-work-1")).to be(true)
  end
end
