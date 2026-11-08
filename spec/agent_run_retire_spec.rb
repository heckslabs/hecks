require "spec_helper"
require "fileutils"
require "json"
require "tmpdir"

# `AgentRun.Retire` through the booted Hecks domain. A stand-in `claude` is first on the search
# path and lists the sessions the example writes, so no real session is listed or touched. A run
# is retired only when the listing does not hold its session.
RSpec.describe "AgentRun.Retire through the Agents port" do
  RETIRE_STAND_IN = <<~SH.freeze
    #!/bin/sh
    here=$(dirname "$0")
    if [ "$1" = "agents" ]; then cat "$here/sessions.json"; exit 0; fi
    printf 'backgrounded · stand-in-session\\n'
  SH

  before(:all) do
    @hecks = Hecks.boot(File.join(InMemoryDomain::ROOT, "lib/hecks/hecks"), install_driving: false)
  end

  let(:scratch) { File.realpath(Dir.mktmpdir("agent-retire")) }

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
    File.write(path, RETIRE_STAND_IN)
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

  def retire(run) = JSON.parse(launch("AgentRun.retire!", "to=#{run}", "--wait").first.to_s)

  # A started run whose session the listing then drops, retired.
  def gone_run(run)
    started_run(run)
    listing
    retire(run)
  end

  it "retires a started run whose session is not listed", :aggregate_failures do
    outcome = gone_run("r-gone")
    expect(outcome.dig("state", "status")).to eq("retired")
    expect(outcome["events"]).to include("AgentRunRetired")
  end

  it "records what the listing said on the retired run" do
    expect(gone_run("r-said").dig("state", "detail")).to eq("session stand-in-session is not listed")
  end

  it "keeps a run whose session is still listed, saying so", :aggregate_failures do
    started_run("r-live")

    outcome = retire("r-live")
    expect(outcome.dig("state", "status")).to eq("started")
    expect(outcome.dig("state", "refusal")).to eq("session stand-in-session is still listed, working")
  end

  it "keeps a run whose sessions cannot be listed", :aggregate_failures do
    started_run("r-unread")
    File.write(File.join(scratch, "claude"), "#!/bin/sh\necho 'daemon down' >&2\nexit 1\n")

    outcome = retire("r-unread")
    expect(outcome.dig("state", "status")).to eq("started")
    expect(outcome.dig("state", "refusal")).to include("could not list sessions")
  end

  it "leaves a retired run out of the running ones" do
    gone_run("r-listed")
    expect(launch("AgentRun.running").first.to_s).not_to include("r-listed")
  end

  it "refuses a run that was never started" do
    expect(launch("AgentRun.retire!", "to=r-unknown", "--wait").first.to_s).not_to include("retired")
  end
end
