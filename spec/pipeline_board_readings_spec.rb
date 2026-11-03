# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "json"
require "hecks/pipeline_board/adapters/pipeline_jobs"
require "hecks/pipeline_board/adapters/pipeline_journal"
require "hecks/pipeline_board/adapters/pipeline_stages/metrics"

# Two readings the board got wrong once: a session waiting on a person showed as fine, and the
# day's finished work was counted inside a window other events could flood out of.
RSpec.describe "PipelineBoard readings" do
  let(:dir) { Dir.mktmpdir("readings") }
  let(:now) { Time.utc(2026, 11, 2, 20, 0, 0) }

  after { FileUtils.rm_rf(dir) }

  def job(id, state)
    FileUtils.mkdir_p(File.join(dir, id))
    File.write(File.join(dir, id, "state.json"), JSON.generate("state" => state, "detail" => "waiting"))
  end

  def sessions(agents)
    Hecks::Adapters::PipelineJobs.new(settings: { jobs_dir: dir, agents: -> { agents }, now: -> { Time.now } }).rows
  end

  it "reads a live job whose state is blocked as blocked, not done" do
    job("s1", "blocked")
    live = sessions([{ "id" => "s1", "name" => "s1", "status" => "idle", "startedAt" => 1 }])
    expect(live.first).to include(status: "blocked", ended: nil)
  end

  it "reads a job that ended in the blocked state as done" do
    job("s2", "blocked")
    stale = Hecks::Adapters::PipelineJobs.new(settings: { jobs_dir: dir, agents: -> { [] }, now: -> { Time.now + 3600 } })
    expect(stale.rows.first).to include(status: "done")
  end

  def finished(ats)
    trace = lambda do |count, event|
      raise "asked for #{event.inspect}, #{count}" unless event == "WorkFinished" && count == 200

      { events: ats.map { |at| { event: { id: at, name: "WorkFinished", aggregate: "Tickets::Work", aggregate_id: "w", occurred_at: at } } } }
    end
    journal = Hecks::Adapters::PipelineJournal.new(settings: { trace: trace, tap: File.join(dir, "none.jsonl"), ttl: 0 })
    journal.named("WorkFinished", 200)
  end

  def throughput(finished)
    tiles = Hecks::Adapters::PipelineBoard::Metrics.tiles({ ci_runs: { unknown: "x" }, finished: finished }, now)
    tiles.find { |tile| tile[:id] == "throughput" }
  end

  it "counts the day's finished work from the events of that name, not from the recent window" do
    rows = finished(["2026-11-02T19:00:00Z", "2026-11-02T01:00:00Z", "2026-11-01T10:00:00Z"])
    expect(throughput(rows)).to include(value: 2, unit: "items / 24 h")
  end

  def working(sessions)
    tiles = Hecks::Adapters::PipelineBoard::Metrics.tiles({ ci_runs: { unknown: "x" }, sessions: sessions }, now)
    tiles.find { |tile| tile[:id] == "working" }
  end

  it "counts only sessions dispatched for a Work row against the cap, and says how many are alive" do
    live = [{ status: "busy", row: "a" }, { status: "busy", row: "" }, { status: "blocked", row: "" },
            { status: "done", row: "b" }]
    expect(working(live)).to include(value: 1, unit: "of 8", detail: "3 sessions alive, 1 blocked on you; load unknown")
  end

  it "says unknown when the journal could not be read" do
    expect(throughput({ unknown: "no store" })).to include(state: "unknown", detail: "unknown: no store")
  end
end
