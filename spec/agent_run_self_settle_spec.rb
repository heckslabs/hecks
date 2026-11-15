require "spec_helper"
require "fileutils"
require "json"
require "tmpdir"

# A run settles itself when its session is gone: a beat of the clock sweeps every started run, and a
# job that still reads working over a session the stand-in `claude` does not list is retired. A
# listed session, a young run and a listing that cannot be read leave the run started.
RSpec.describe "A beat retires the started run whose session is not listed" do
  SETTLE_STAND_IN = <<~SH.freeze
    #!/bin/sh
    here=$(dirname "$0")
    if [ "$1" = "agents" ]; then cat "$here/sessions.json"; exit 0; fi
    printf 'backgrounded · stand-in-session\\n'
  SH

  before(:all) do
    @hecks = boot_hecks_in_memory
  end

  let(:scratch) { File.realpath(Dir.mktmpdir("agent-settle")) }

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
    @clock = Time.now.utc
    allow(Hecks::Adapters::ClaudeAgents).to(receive(:new).and_wrap_original do |original, **context|
      original.call(**context, settings: { jobs: File.join(scratch, "jobs"), settle: 0, now: -> { @clock } })
    end)
  end

  def install_stand_in
    path = File.join(scratch, "claude")
    File.write(path, SETTLE_STAND_IN)
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

  def beat(key) = launch("heartbeat.beat!", "beat.value=#{key}", "--wait")

  def running = launch("AgentRun.running").first.to_s

  def swept_run(run, after: 300, gone: true)
    started_run(run)
    listing if gone
    @clock += after
    beat("beat-#{run}")
  end

  it "retires a working run whose session is not listed, with no hand check_all" do
    swept_run("s-gone")
    expect(running).not_to include("s-gone")
  end

  it "keeps a working run whose session is still listed" do
    swept_run("s-live", gone: false)
    expect(running).to include("s-live")
  end

  it "keeps a run started seconds ago whose session is not listed yet" do
    swept_run("s-young", after: 10)
    expect(running).to include("s-young")
  end

  it "keeps a run whose sessions cannot be listed" do
    started_run("s-down")
    File.write(File.join(scratch, "claude"), "#!/bin/sh\necho 'daemon down' >&2\nexit 1\n")
    @clock += 300
    beat("beat-s-down")
    expect(running).to include("s-down")
  end
end
