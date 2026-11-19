# frozen_string_literal: true

require "spec_helper"
require_relative "support/stand_in_claude"

# An AgentRun names the run whose reaction dispatched it (`parent`), so a fan-out's depth can be
# read from `AgentRun.running`. A stand-in `claude` starts every session, so no real one runs.
RSpec.describe "an AgentRun's parent run" do
  include_context "with a stand-in claude"

  before(:all) do
    @hecks = boot_hecks_in_memory
  end

  def launch(*argv) = Hecks::Adapters::Driving::CliRunner.call(runtime: @hecks, argv: argv, program: "hecks")

  def dispatch(run, *named)
    launch("agent_run.dispatch!", "run.value=#{run}", "repo.value=#{scratch}", "brief.value=say ok", *named, "--wait")
  end

  def running(run) = JSON.parse(launch("agent_run.running").first).find { |row| row["run"] == run }

  def finish(run)
    File.write(File.join(scratch, "jobs", "stand-in-session", "state.json"), JSON.generate(state: "done"))
    File.write(File.join(scratch, "sessions.json"), JSON.generate([{ id: "stand-in-session", state: "done" }]))
    launch("agent_run.check!", "to=#{run}", "--wait")
  end

  it "lists a run dispatched with a parent as running under that parent" do
    dispatch("p-child", "parent.value=p-coder")
    expect(running("p-child")).to include("parent" => "p-coder")
  end

  it "lists a run dispatched with no parent as having none" do
    dispatch("p-alone")
    expect(running("p-alone")["parent"]).to be_nil
  end

  it "starts a reused key's new run with no parent when its dispatch names none" do
    first = dispatch("p-again", "parent.value=p-first")
    finish("p-again")
    parents = [first, dispatch("p-again")].map { |out| JSON.parse(out.first).dig("state", "parent") }
    expect(parents).to eq(["p-first", nil])
  end

  it "starts the architect's plan review run under the coder run of the Work item it reviews" do
    launch("agents", "PlanReview.request!", "run.value=p-review", "work.value=p-item", "hops.value=1",
           "role.value=architect", "repo.value=#{scratch}", "plan.value=review this plan as written", "--wait")
    expect(running("p-review")).to include("parent" => "p-item", "work" => "p-item")
  end

  it "starts the reviewer's submission run under the submitting coder's run" do
    launch("coder", "Submission.submit!", "branch.value=p-branch", "sha.value=abc7001", "checkout.value=#{scratch}",
           "clean.value=true", "--wait")
    expect(running("abc7001")).to include("parent" => "p-branch")
  end
end
