require "spec_helper"
require_relative "support/stand_in_claude"

# A session `claude agents` lists as idle after its closing words has finished its turn, though its
# job still reads `working`. Through the booted Hecks domain: the next check ends the run `done`,
# and a session still busy, or an orchestrator idle between beats, stays started. The stand-in
# `claude` lists the session with the status a spec writes.
RSpec.describe "AgentRun: a session idle after its closing words" do
  include_context "with a stand-in claude"

  before(:all) do
    @hecks = boot_hecks_in_memory
  end

  def listed(status)
    File.write(File.join(scratch, "sessions.json"), JSON.generate([{ id: "stand-in-session", status: status }]))
  end

  def job(report)
    state = JSON.generate(state: "working", output: { result: report })
    File.write(File.join(scratch, "jobs", "stand-in-session", "state.json"), state)
  end

  def launch(*argv) = Hecks::Adapters::Driving::CliRunner.call(runtime: @hecks, argv: argv, program: "hecks")

  def check(run) = JSON.parse(launch("agent_run.check!", "to=#{run}", "--wait").first.to_s).fetch("state")

  def started(run, agent)
    launch("agent_run.dispatch!", "run.value=#{run}", "repo.value=#{scratch}", "brief.value=say ok",
           "agent.value=#{agent}", "--wait")
    check(run)
  end

  it "ends an idle coder's run done on the next check", :aggregate_failures do
    started("r-idle-coder", "coder")
    listed("idle")
    job("Landed.")

    expect(check("r-idle-coder")).to include("status" => "finished", "condition" => "done")
  end

  it "leaves a busy session's run started" do
    started("r-busy-coder", "coder")
    listed("busy")
    job("Landed.")

    expect(check("r-busy-coder")).to include("status" => "started")
  end

  it "leaves an idle session that has said nothing started" do
    started("r-quiet-coder", "coder")
    listed("idle")
    job("")

    expect(check("r-quiet-coder")).to include("status" => "started")
  end

  it "leaves an idle orchestrator's run started" do
    started("r-idle-orchestrator", "orchestrator")
    listed("idle")
    job("Beat done.")

    expect(check("r-idle-orchestrator")).to include("status" => "started")
  end
end
