require "spec_helper"
require "hecks/hecks/adapters/stall_watching"

# Tap lines of one coder run and the agent-run-unresumed row: a filed stall whose line closed is
# abandoned once its run is tidied, and only then. The lines a spec builds are in sequence order.
module EndedRunLooks
  NOW = Time.utc(2026, 11, 18, 12, 0, 0)
  KIND = { kind: "agent-run-unresumed", not_about: "stall-", aggregate: "Hecks::AgentRun", opens: "AgentRunUnresumed",
           closes: "AgentRunAnswered,SessionFinished", ends_aggregate: "Hecks::AgentRun",
           ends: "AgentRunTidied,AgentRunRetired", minutes: 10, forgets: 1440, fixer: "orchestrator", move: "look" }.freeze

  def run_line(event, minutes_ago)
    { "kind" => "event", "at" => (NOW - (minutes_ago * 60)).iso8601, "aggregate" => "Hecks::AgentRun",
      "id" => "run-1", "event" => event }
  end

  def filed(kind = "agent-run-unresumed") = { "kind" => "event", "event" => "StallFiled", "id" => "stall-#{kind}-run-1" }

  # The stall opened `ago` minutes back, was filed, answered a minute later, then `events` followed.
  def answered_then(*events, ago: 60)
    [run_line("AgentRunUnresumed", ago), filed, run_line("AgentRunAnswered", ago - 1)] +
      events.map { |event| run_line(event, ago - 2) }
  end

  def no_ending = KIND.merge(kind: "train-pr-red", ends_aggregate: nil, ends: nil)

  def sightings(kind = KIND) = Hecks::Adapters::StallWatching::Sightings.new([kind], NOW.to_i)

  def abandoned(lines, kind = KIND) = sightings(kind).abandoned(lines, "look")

  def rows(lines) = sightings.rows(lines, "look")
end

RSpec.describe Hecks::Adapters::StallWatching::Sightings do
  include EndedRunLooks

  it "abandons a filed stall whose line closed once its run is tidied" do
    expect(abandoned(answered_then("AgentRunTidied")).map { |row| row[:reason] }.join).to include("AgentRunTidied")
  end

  it "abandons nothing for a filed stall whose line closed while its run goes on" do
    expect(abandoned(answered_then)).to be_empty
  end

  it "abandons nothing for a closed line of a kind that names no ending" do
    lines = [run_line("AgentRunUnresumed", 60), filed("train-pr-red"), run_line("AgentRunAnswered", 59)]

    expect(abandoned(lines, no_ending)).to be_empty
  end

  it "abandons nothing for a filed stall older than its kind's window" do
    expect(abandoned(answered_then("AgentRunTidied", ago: 1500))).to be_empty
  end

  it "abandons nothing for an ending that came before the stall opened" do
    expect(abandoned([run_line("AgentRunTidied", 70), run_line("AgentRunUnresumed", 60), filed])).to be_empty
  end

  it "sights a later attempt's open line that an earlier attempt's tidy came before" do
    lines = [run_line("AgentRunTidied", 70), run_line("AgentRunUnresumed", 60)]

    expect(rows(lines).map { |row| row[:subject] }).to eq(%w[run-1])
  end
end
