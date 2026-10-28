require "spec_helper"
require "fileutils"
require "json"
require "tmpdir"

# `AgentRun` through the booted Hecks domain, with a stand-in `claude` first on the search path: a
# dispatch is requested, the directory is looked for, a session is started and recorded, and a
# check reads the state the session reports. The stand-in prints a session id and lists the
# sessions a spec writes, so no real session is ever started.
RSpec.describe "AgentRun through the Agents port" do
  STAND_IN_CLAUDE = <<~SH.freeze
    #!/bin/sh
    here=$(dirname "$0")
    if [ "$1" = "agents" ]; then cat "$here/sessions.json"; exit 0; fi
    printf 'backgrounded · stand-in-session\\n  claude agents    list sessions\\n'
  SH

  before(:all) do
    @hecks = Hecks.boot(File.join(InMemoryDomain::ROOT, "lib/hecks/hecks"), install_driving: false)
  end

  let(:scratch) { File.realpath(Dir.mktmpdir("agent-run")) }
  let(:stand_in) { File.join(scratch, "claude") }

  around do |example|
    path = ENV.fetch("PATH")
    install_stand_in
    ENV["PATH"] = "#{scratch}:#{path}"
    example.run
  ensure
    ENV["PATH"] = path
    FileUtils.rm_rf(scratch)
  end

  def install_stand_in
    File.write(stand_in, STAND_IN_CLAUDE)
    File.chmod(0o755, stand_in)
    listing("stand-in-session" => "busy")
  end

  def listing(states)
    File.write(File.join(scratch, "sessions.json"), JSON.generate(states.map { |id, state| { id: id, state: state } }))
  end

  def launch(*argv) = Hecks::Adapters::Driving::CliRunner.call(runtime: @hecks, argv: argv, program: "hecks")

  def dispatch(run, repo: scratch, brief: "say ok")
    launch("agent_run.dispatch!", "run.value=#{run}", "repo.value=#{repo}", "brief.value=#{brief}", "--wait")
  end

  def running = JSON.parse(launch("query", "agent_run.running").first)

  it "starts a session in a directory that is there, and lists it as running", :aggregate_failures do
    out, = dispatch("a-start")

    expect(JSON.parse(out).dig("state", "status")).to eq("started")
    expect(running.map { |row| row["session"] }).to include("stand-in-session")
  end

  it "declines a directory that is not there, and lists nothing as running", :aggregate_failures do
    out, = dispatch("a-absent", repo: File.join(scratch, "absent"))

    expect(JSON.parse(out).dig("state", "status")).to eq("refused")
    expect(running.map { |row| row["run"] }).not_to include("a-absent")
  end

  it "finishes a run whose session reports done, so it is no longer running", :aggregate_failures do
    dispatch("a-done")
    listing("stand-in-session" => "done")
    launch("agent_run.check!", "to=a-done", "--wait")

    expect(running.map { |row| row["run"] }).not_to include("a-done")
  end

  it "keeps a run running while its session reports busy" do
    dispatch("a-busy")
    launch("agent_run.check!", "to=a-busy", "--wait")

    expect(running.map { |row| row["run"] }).to include("a-busy")
  end
end
