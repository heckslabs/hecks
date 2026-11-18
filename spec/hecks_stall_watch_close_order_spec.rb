require "spec_helper"
require "hecks/hecks/adapters/stall_watching"

# Tap lines of one coder run and the agent-run-blocked row, for the close-order group. The lines a
# spec builds are in sequence order, as the tap holds them.
module CloseOrderLooks
  NOW = Time.utc(2026, 11, 16, 12, 0, 0)
  KIND = { kind: "agent-run-blocked", not_about: "stall-", aggregate: "Hecks::AgentRun", opens: "SessionBlocked",
           closes: "AnswerRequested,AgentRunAnswered,SessionWorking,SessionFinished", minutes: 15, forgets: 1440,
           fixer: "orchestrator", move: "look" }.freeze

  def run_line(event, minutes_ago, branch = nil)
    line = { "kind" => "event", "at" => (NOW - (minutes_ago * 60)).iso8601, "aggregate" => "Hecks::AgentRun",
             "id" => "run-1", "event" => event }
    branch ? line.merge("links" => { "branch" => branch }) : line
  end

  def filed = { "kind" => "event", "event" => "StallFiled", "id" => "stall-agent-run-blocked-run-1" }

  def sightings = Hecks::Adapters::StallWatching::Sightings.new([KIND], NOW.to_i)

  def rows(lines) = sightings.rows(lines, "look")

  def openings(lines) = Hecks::Adapters::StallWatching::Openings.new(KIND, lines)
end

# A closing line closes only the opening lines before it: a session writes SessionWorking before
# each SessionBlocked on the same run, and that block still files its stall.
RSpec.describe Hecks::Adapters::StallWatching::Openings do
  include CloseOrderLooks

  it "files a block that a working line came before" do
    lines = [run_line("SessionWorking", 30), run_line("SessionBlocked", 20)]

    expect(rows(lines).map { |row| row[:stall] }).to eq(%w[stall-agent-run-blocked-run-1])
  end

  it "files nothing for a block a working line came after" do
    expect(rows([run_line("SessionBlocked", 40), run_line("SessionWorking", 30)])).to be_empty
  end

  it "ages a block that opened again from its reopening line" do
    lines = [run_line("SessionBlocked", 90), run_line("SessionWorking", 80), run_line("SessionBlocked", 20)]

    expect(rows(lines).map { |row| row[:waited] }).to eq([20])
  end

  it "lets a closing line with no opening before it cancel nothing after it" do
    expect(openings([run_line("AgentRunAnswered", 30), run_line("SessionBlocked", 20)]).unclosed.keys).to eq(%w[run-1])
  end

  it "files no second item for a block that reopened while the first stands filed", :aggregate_failures do
    lines = [run_line("SessionBlocked", 90), filed, run_line("SessionWorking", 80), run_line("SessionBlocked", 20)]

    expect(rows(lines)).to be_empty
    expect(sightings.abandoned(lines, "look")).to be_empty
  end

  it "reads the branch of the reopening line, not the first one" do
    lines = [run_line("SessionBlocked", 90, "old"), run_line("SessionWorking", 80), run_line("SessionBlocked", 20, "new")]

    expect(openings(lines).branch("run-1")).to eq("new")
  end
end
