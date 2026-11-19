require "spec_helper"
require "hecks/agents/adapters/fleet_control"
require_relative "support/agents_fleet_helpers"

# The background sessions as an operator steers them: listed with their runs, found by what their
# transcripts say, stopped and resumed under a name. Every session, transcript and run here is a
# stand-in under a temporary directory; no `claude` command is run.
RSpec.describe "the Agents fleet of sessions" do
  include AgentsFleetHelpers

  before { boot_fleet }

  after { FileUtils.rm_rf(projects) }

  it "lists each session with the run that holds it" do
    expect(fleet.sessions[:text].lines.first.strip).to eq("aaaa1111  coder-one  done/idle  run fix-it started working")
  end

  it "says a session no run holds" do
    expect(fleet.sessions[:text].lines.last).to end_with("no run")
  end

  it "finds a session by what its transcript says, in any case", :aggregate_failures do
    transcript("cccc3333-full", "nothing here", "Fix the Landing queue")
    found = fleet.topic(topic: "landing QUEUE")[:text]
    expect(found).to start_with("cccc3333  plain")
    expect(found).to end_with("said: Fix the Landing queue")
  end

  it "says when no listed session mentions the topic" do
    transcript("aaaa1111-full", "something else")
    expect(fleet.topic(topic: "landing")[:text]).to eq("no listed session mentions landing")
  end

  it "stops a listed session with claude stop and records it", :aggregate_failures do
    stopped = steer(:stop!, "aaaa1111")
    expect(stopped.status).to eq("stopped")
    expect(shell.commands.first[:command]).to eq(%w[claude stop aaaa1111])
  end

  it "records the run that holds the stopped session" do
    expect(steer(:stop!, "aaaa1111").run.value).to eq("fix-it")
  end

  it "refuses to stop the session of a pinned role, by name", :aggregate_failures do
    refused = steer(:stop!, "bbbb2222")
    expect(refused.refusal.value).to include("holds the pinned role orchestrator")
    expect(shell.commands).to be_empty
  end

  it "refuses a session claude does not list" do
    expect(steer(:stop!, "dddd4444").refusal.value).to include("session dddd4444 is not listed by claude agents")
  end

  it "resumes a session under a name, from the directory it worked in", :aggregate_failures do
    transcript("cccc3333-full", "hello", cwd: "/work/plain")
    expect(steer(:resume!, "cccc3333", name: { value: "plain-two" }).status).to eq("resumed")
    expect(shell.commands.first).to eq(command: %w[claude --bg --resume cccc3333-full -n plain-two], chdir: "/work/plain")
  end

  it "refuses to resume a working session, running no command", :aggregate_failures do
    expect(steer(:resume!, "bbbb2222", name: { value: "again" }).refusal.value).to include("is working")
    expect(shell.commands).to be_empty
  end

  it "examines a session to stop by its facts, judging nothing" do
    expect(fleet.examine_stop(session: { value: "bbbb2222" })).to include(pinned: true, run: { value: "" })
  end

  it "examines a session to resume by its facts, keeping its name" do
    facts = fleet.examine_resume(session: { value: "aaaa1111" }, name: { value: "next" })
    expect(facts).to include(working: false, run: { value: "fix-it" }, name: { value: "next" })
  end

  it "refuses to examine a session claude does not list" do
    expect { fleet.examine_stop(session: "dddd4444") }.to raise_error(Hecks::Adapters::ConsoleCapture::Failure, /not listed/)
  end

  it "refuses a name that could be read as a flag" do
    expect { steer(:resume!, "cccc3333", name: { value: "-p" }) }.to raise_error(StandardError, /FleetName|pattern|value/)
  end

  it "refuses every read where no AgentRun ledger is booted" do
    adapter = Hecks::Adapters::FleetControl.new(settings: { shell: shell, projects: projects })
    expect { adapter.sessions }.to raise_error(Hecks::Adapters::ConsoleCapture::Failure, /not booted here/)
  end
end
