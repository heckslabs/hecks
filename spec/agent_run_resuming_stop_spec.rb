require "spec_helper"
require_relative "support/stand_in_claude"

# Delivering an answer stops the session and wakes it again. Through the booted Hecks domain: a job
# read `stopped` while the answer is on its way ends nothing, the run is started and working once
# the session is woken, and a stop with no answer on its way, or after the answer was refused,
# still finishes the run. A stand-in resumption takes the place of `claude stop` and `--resume`,
# and has the run checked while the session is stopped, as the session's own hook does.
RSpec.describe "AgentRun: a stop its own answer caused" do
  include_context "with a stand-in claude"

  before(:all) do
    @hecks = boot_hecks_in_memory
  end

  let(:seen) { [] }

  def job(state) = File.write(File.join(scratch, "jobs", "stand-in-session", "state.json"), JSON.generate(state: state))

  def launch(*argv) = Hecks::Adapters::Driving::CliRunner.call(runtime: @hecks, argv: argv, program: "hecks")

  def check(run) = JSON.parse(launch("agent_run.check!", "to=#{run}", "--wait").first.to_s).fetch("state")

  def started_run(run)
    launch("agent_run.dispatch!", "run.value=#{run}", "repo.value=#{scratch}", "brief.value=say ok", "--wait")
    check(run)
  end

  # What the stand-in resumption does: stops the session, has the run checked, then wakes the
  # session or refuses.
  def resume(run, wakes)
    job("stopped")
    seen << check(run)
    raise Hecks::Adapters::ConsoleCapture::Failure, "claude resume refused" unless wakes

    job("working")
    { resumed_at: { value: "2026-11-10T22:11:46Z" }, session: { value: "stand-in-session" } }
  end

  def answer(run, wakes: true)
    resumption = instance_double(Hecks::Adapters::ClaudeResumption)
    allow(resumption).to receive(:call) { resume(run, wakes) }
    allow(Hecks::Adapters::ClaudeResumption).to receive(:new).and_return(resumption)
    launch("agent_run.answer!", "to=#{run}", "answer.value=go on", "--wait")
  end

  it "does not end the run on the stop its own answer caused", :aggregate_failures do
    started_run("r-in-flight")
    answer("r-in-flight")

    expect(seen.first).to include("status" => "started", "resuming" => true)
    expect(seen.first["condition"]).not_to eq("stopped")
  end

  it "leaves the run started and not resuming once the session is woken", :aggregate_failures do
    started_run("r-woken")
    answer("r-woken")

    expect(check("r-woken")).to include("status" => "started", "condition" => "working", "resuming" => false)
  end

  it "ends the run as stopped on the next check when the answer was refused", :aggregate_failures do
    started_run("r-refused")
    answer("r-refused", wakes: false)

    expect(seen.first).to include("status" => "started")
    expect(check("r-refused")).to include("status" => "finished", "condition" => "stopped", "resuming" => false)
  end

  it "ends the run at once on a stop with no answer on its way" do
    started_run("r-stopped")
    job("stopped")

    expect(check("r-stopped")).to include("status" => "finished", "condition" => "stopped")
  end

  it "ends the run at once when the session is done, an answer on its way or not" do
    started_run("r-done")
    job("done")

    expect(check("r-done")).to include("status" => "finished", "condition" => "done")
  end
end
