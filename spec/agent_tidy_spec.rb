require "spec_helper"
require "fileutils"
require "json"
require "tmpdir"

# `AgentRun.Tidy` through the booted Hecks domain. A stand-in `claude` is first on the search path
# and records each `rm <id>` in a log, and `HOME` points at a scratch directory holding fake
# transcripts, so no real session is listed, read or removed.
RSpec.describe "AgentRun.Tidy through the Agents port" do
  TIDY_STAND_IN = <<~SH.freeze
    #!/bin/sh
    here=$(dirname "$0")
    if [ "$1" = "agents" ]; then cat "$here/sessions.json"; exit 0; fi
    if [ "$1" = "rm" ]; then echo "$2" >> "$here/rm.log"; exit 0; fi
    printf 'backgrounded · stand-in-session\\n'
  SH

  FULL_ID = "0000aaaa-1111-2222-3333-444455556666".freeze

  before(:all) do
    @hecks = Hecks.boot(File.join(InMemoryDomain::ROOT, "lib/hecks/hecks"), install_driving: false)
  end

  let(:scratch) { File.realpath(Dir.mktmpdir("agent-tidy")) }
  let(:removed) { File.exist?(File.join(scratch, "rm.log")) ? File.readlines(File.join(scratch, "rm.log"), chomp: true) : [] }

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

  def install_stand_in
    path = File.join(scratch, "claude")
    File.write(path, TIDY_STAND_IN)
    File.chmod(0o755, path)
  end

  def sessions(state)
    File.write(File.join(scratch, "sessions.json"), JSON.generate([{ id: "stand-in-session", sessionId: FULL_ID, state: state }]))
  end

  def transcript(*entries)
    dir = File.join(scratch, ".claude", "projects", "p")
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, "#{FULL_ID}.jsonl"), entries.map { |entry| JSON.generate(entry) }.join("\n"))
  end

  def user(text) = { type: "user", message: { content: text } }
  def tool_result = { type: "user", message: { content: [{ type: "tool_result", content: "ok" }] } }

  def launch(*argv) = Hecks::Adapters::Driving::CliRunner.call(runtime: @hecks, argv: argv, program: "hecks")

  def finished_run(run, state)
    launch("agent_run.dispatch!", "run.value=#{run}", "repo.value=#{scratch}", "brief.value=say ok", "--wait")
    sessions(state)
    launch("agent_run.check!", "to=#{run}", "--wait")
  end

  def tidy(run) = launch("agent_run.tidy!", "to=#{run}", "--wait").first.to_s
  def refusal(run) = tidy(run)
  def status(out) = out.dig("state", "status")

  it "removes a done session nobody replied in, and records it", :aggregate_failures do
    transcript(user("say ok"), tool_result)
    finished_run("t-done", "done")

    expect(status(JSON.parse(tidy("t-done")))).to eq("tidied")
    expect(removed).to eq(["stand-in-session"])
  end

  it "keeps a session a person replied in", :aggregate_failures do
    transcript(user("say ok"), tool_result, user("actually, also do this"))
    finished_run("t-human", "done")

    expect(status(JSON.parse(tidy("t-human")))).to eq("finished")
    expect(removed).to be_empty
  end

  it "keeps a session whose transcript cannot be found", :aggregate_failures do
    finished_run("t-lost", "done")

    expect(status(JSON.parse(tidy("t-lost")))).to eq("finished")
    expect(removed).to be_empty
  end

  it "refuses a session that stopped rather than finishing, and removes nothing", :aggregate_failures do
    finished_run("t-stopped", "stopped")

    expect(refusal("t-stopped")).to include("ended done")
    expect(removed).to be_empty
  end

  it "refuses a run that was never dispatched, and removes nothing", :aggregate_failures do
    expect(refusal("t-unknown")).not_to include("tidied")
    expect(removed).to be_empty
  end
end
