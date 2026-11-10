# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "hecks/pipeline_board/adapters/pipeline_stages"

# The pipeline's own day, read from a fake event log: what a person would otherwise find by
# watching. The `HealthCheck` rows of pipeline_board.bluebook say which events open and close each
# check; these examples read a scratch log through the Journal reader and the rows.
module HealthJournal
  NOW = Time.parse("2026-11-10T18:00:00Z")

  def line(at, aggregate, id, event, links = {})
    { "kind" => "event", "at" => at, "aggregate" => aggregate, "id" => id, "event" => event, "links" => links }
  end

  def turn(at, id, payload) = line(at, "Agents::Turn", id, "TurnFinished").merge("payload" => payload)

  def boardings
    [line("2026-11-10T10:00:00Z", "Hecks::Integration", "v-1", "MainVerified", "landed" => "aaaaaaa111"),
     line("2026-11-10T10:01:00Z", "Hecks::Integration", "b-1", "MainBoardingStarted", "landed" => "aaaaaaa111"),
     line("2026-11-10T10:02:00Z", "Hecks::SendTrain", "t-1", "BoardingQueued", "boarded" => "aaaaaaa111"),
     line("2026-11-10T11:00:00Z", "Hecks::Integration", "v-2", "MainVerified", "landed" => "bbbbbbb222"),
     line("2026-11-10T11:05:00Z", "Hecks::SendTrain", "t-2", "BoardingQueued", "boarded" => "bbbbbbb222"),
     line("2026-11-10T12:00:00Z", "Hecks::SendTrain", "t-3", "BoardingQueued", "boarded" => "ccccccc333")]
  end

  def verifications
    [line("2026-11-10T09:00:00Z", "Hecks::Integration", "v-slow", "MainVerificationStarted", "landed" => "d1"),
     line("2026-11-10T09:41:00Z", "Hecks::Integration", "v-slow", "MainVerified", "landed" => "d1"),
     line("2026-11-10T13:00:00Z", "Hecks::Integration", "v-fast", "MainVerificationStarted", "landed" => "d2"),
     line("2026-11-10T13:16:00Z", "Hecks::Integration", "v-fast", "MainVerificationFailed", "landed" => "d2"),
     line("2026-11-10T17:00:00Z", "Hecks::Integration", "v-hung", "MainVerificationStarted", "landed" => "d3")]
  end

  def deliveries
    stuck = { "verdict" => "done", "stuck" => [{ "kind" => "owner", "what" => "the world line" }] }
    [turn("2026-11-10T14:00:00Z", "half", stuck),
     line("2026-11-10T14:01:00Z", "Tickets::Work", "half", "WorkFinished"),
     turn("2026-11-10T15:00:00Z", "whole", { "verdict" => "done" }),
     line("2026-11-10T15:01:00Z", "Tickets::Work", "whole", "WorkFinished")]
  end

  def findings
    [line("2026-11-07T18:00:00Z", "Tickets::Finding", "old", "StoppedRunReported"),
     line("2026-11-10T17:00:00Z", "Tickets::Finding", "new", "FindingReported")]
  end

  def sessions
    [{ id: "s-blocked", name: "waits", status: "blocked", state: "blocked", started: "2026-11-10T15:00:00Z" },
     { id: "s-fresh", name: "asks", status: "blocked", state: "blocked", started: "2026-11-10T17:50:00Z" },
     { id: "s-stopped", name: "halted", status: "done", state: "stopped", started: "2026-11-10T08:00:00Z",
       ended: "2026-11-10T09:00:00Z" },
     { id: "s-done", name: "fine", status: "done", state: "done", ended: "2026-11-10T09:00:00Z" }]
  end

  def open_findings = [{ finding: "old" }, { finding: "new" }, { finding: "unlogged" }]

  def journal(lines)
    path = File.join(Dir.mktmpdir("health"), "events.jsonl")
    File.write(path, lines.map { |entry| "#{JSON.generate(entry)}\n" }.join)
    Hecks::Adapters::PipelineJournal.new(settings: { tap: path, trace: ->(*) { { "events" => [] } } })
  end

  def health = Hecks::Adapters::PipelineBoard::DailyHealth

  def report
    events = journal(boardings + verifications + deliveries + findings).health_events
    health.build({ health_events: events, sessions: sessions, open_findings: open_findings }, NOW)
  end

  def built_from(events) = health.build({ health_events: events, sessions: [], open_findings: [] }, NOW)

  def ids(kind) = report[kind].map { |row| row[:key] }
end

RSpec.describe "the pipeline's daily health line" do
  include HealthJournal

  it "names a boarding the advance did not board, and one whose commit was never verified", :aggregate_failures do
    expect(ids(:boarded_by_hand)).to eq(%w[bbbbbbb222 ccccccc333])
    expect(ids(:boarded_unverified)).to eq(%w[ccccccc333])
  end

  it "names a verification over its bound, and one still open past it", :aggregate_failures do
    expect(ids(:slow_verification)).to eq(%w[v-slow v-hung])
    expect(report[:slow_verification].first[:minutes]).to eq(41)
  end

  it "names a Work item finished while its run's last turn left parts stuck" do
    expect(ids(:half_delivered)).to eq(%w[half])
  end

  it "names sessions left blocked or stopped past the bound, with the age of each", :aggregate_failures do
    expect(ids(:left_session)).to eq(%w[s-blocked s-stopped])
    expect(report[:left_session].map { |row| row[:minutes] }).to eq([180, 540])
  end

  it "names open findings older than the bound, and those opened before the log" do
    expect(ids(:stale_finding)).to eq(%w[old unlogged])
  end

  it "says it all in one line, each finding with its age", :aggregate_failures do
    expect(report[:line]).to start_with("pipeline health 2026-11-10: 2 boarded by hand (bbbbbbb222 ccccccc333), ")
    expect(report[:line]).to include("2 slow verifications (v-slow 41m v-hung 60m)", "2 stale findings (old 72h unlogged)")
  end

  it "says nothing was found on a quiet day" do
    expect(built_from([])[:line]).to eq("pipeline health 2026-11-10: nothing found")
  end

  it "says unknown for a check whose reading failed" do
    expect(built_from({ unknown: "no log" })[:slow_verification]).to eq({ unknown: "no log" })
  end

  it "lists a boarding whose commit link cannot be read instead of dropping it" do
    odd = journal([line("2026-11-10T12:00:00Z", "Hecks::SendTrain", "t-9", "BoardingQueued", "boarded" => "#<Value>")])
    expect(built_from(odd.health_events)[:unreadable].map { |row| row[:key] }).to eq(%w[t-9])
  end

  it "gives the board a tile counting what only the events show", :aggregate_failures do
    tile = health.tile(report)
    expect(tile[:value]).to eq(6)
    expect(tile[:state]).to eq("attention")
  end
end
