# frozen_string_literal: true

require "spec_helper"
require "hecks/roundhouse/adapters/metering"

# Roundhouse's `Ended` meter (ADR 0222, phase 3, reaping): the finished and stale sessions and the
# checkout's copies a reap is ruled on. Every outside read is a stand-in here.
RSpec.describe Hecks::Adapters::Metering do
  let(:now) { Time.utc(2026, 11, 19, 18, 0, 0) }

  let(:listing) do
    started = (now.to_i - 3600) * 1000
    [
      { "id" => "aaaa", "sessionId" => "aaaa-full", "pid" => 100, "kind" => "background", "state" => "working",
        "startedAt" => started, "cwd" => "/repo/.claude/worktrees/mine/lib" },
      { "id" => "bbbb", "sessionId" => "bbbb-full", "kind" => "background", "state" => "done", "startedAt" => started,
        "cwd" => "/repo" },
      { "id" => "cccc", "sessionId" => "cccc-full", "pid" => 300, "kind" => "background", "state" => "blocked",
        "startedAt" => started, "cwd" => "/repo" },
      { "sessionId" => "dddd-full", "kind" => "interactive", "state" => "done", "startedAt" => started }
    ]
  end

  let(:copies) do
    [{ path: "/repo/.claude/worktrees/mine", branch: "mine", landed: "yes", unsaved: 0, idle_minutes: 9 },
     { path: "/repo/.claude/worktrees/tiles", branch: "tiles", landed: "yes", unsaved: 0, idle_minutes: 90 }]
  end

  let(:ended) do
    runs = { "bbbb-full" => { run: "r-done", agent: "reviewer", status: "finished" } }
    described_class.new(settings: { listing: -> { listing }, processes: -> { "  100     1  1024  1.0 claude\n" },
                                    runs: -> { runs }, activity: ->(_entry) { now - 600 }, now: -> { now },
                                    copies: -> { copies } }).ended_facts
  end

  it "meters a done session as finished and a listed one with no process as stale, never a working one" do
    expect(ended[:sessions].to_h { |row| [row[:id], row[:kind]] }).to eq("bbbb" => "finished", "cccc" => "stale")
  end

  it "carries the session's run, its status and its idle minutes", :aggregate_failures do
    row = ended[:sessions].find { |found| found[:id] == "bbbb" }
    expect(row.slice(:run, :run_status, :role, :live)).to eq(run: "r-done", run_status: "finished", role: "helper", live: "no")
    expect(row[:idle_minutes]).to eq(10)
  end

  it "marks a copy a live session works in as held" do
    expect(ended[:copies].to_h { |copy| [copy[:branch], copy[:held]] }).to eq("mine" => "yes", "tiles" => "no")
  end
end
