require "spec_helper"
require_relative "support/brief_commands"

# Every command a brief, a role file or a stall move tells a guarded role to run passes that role's
# routing guard, so a run never blocks on a step its own brief named. Reads only the bluebooks.
RSpec.describe "the commands a brief tells a role to run" do
  include BriefCommands

  it "pass the role's routing guard, each refusal named by role, source and command" do
    expect(refused.map { |row| row.join(" | ") }).to eq([])
  end

  it "are found for the orchestrator, so the walk is not empty" do
    expect(commands.map(&:first)).to include("orchestrator", "planner")
  end

  it "fill a placeholder, which would otherwise read as a redirection" do
    expect(named("run `exe/hecks AgentRun.answer! to=<run> ...` now")).to eq(["exe/hecks AgentRun.answer! to=x"])
  end

  it "read a move's bare verbs and its parenthesised gh calls" do
    expect(named("Work.yield! it (gh pr close, gh pr reopen).", move: true)).to include("exe/hecks Work.yield!", "gh pr reopen")
  end

  it "wake a stall's run with the stall's own detail, its subject and move filled in" do
    expect(stall_wake_brief).to eq(:detail)
  end

  it "leave out the words written for another role, which drop the launcher prefix" do
    expect(named("verify with `test_suite_run.run_impacted_specs!`")).to eq([])
  end
end
