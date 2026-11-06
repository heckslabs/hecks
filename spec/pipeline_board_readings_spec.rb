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

  def job(id, state, needs: nil)
    FileUtils.mkdir_p(File.join(dir, id))
    File.write(File.join(dir, id, "state.json"),
               JSON.generate({ "state" => state, "detail" => "waiting", "needs" => needs }.compact))
  end

  def sessions(agents)
    Hecks::Adapters::PipelineJobs.new(settings: { jobs_dir: dir, agents: -> { agents }, now: -> { Time.now } }).rows
  end

  # The kind a blocked session's question carries, read from the bracket it begins with.
  def kind_of(detail)
    FileUtils.mkdir_p(File.join(dir, "q"))
    File.write(File.join(dir, "q", "state.json"), JSON.generate("state" => "blocked", "detail" => detail, "needs" => detail))
    sessions([{ "id" => "q", "name" => "q", "status" => "idle", "startedAt" => 1 }]).first[:question_kind]
  end

  it "reads a blocked session's question kind from the bracket its question begins with", :aggregate_failures do
    expect(kind_of("[confirm] Run the specs again?")).to eq("confirm")
    expect(kind_of("[OWNER] Push main?")).to eq("owner")
    expect(kind_of("Which branch should I use?")).to eq("")
  end

  # A blocked job's state names what it needs and the reply Claude Code suggests for it.
  def context_with(state)
    FileUtils.mkdir_p(File.join(dir, "r"))
    File.write(File.join(dir, "r", "state.json"), JSON.generate({ "state" => "blocked", "detail" => "waiting" }.merge(state)))
    sessions([{ "id" => "r", "name" => "r", "status" => "idle", "startedAt" => 1 }]).first[:context]
  end

  it "carries a blocked session's needs and suggested reply to the answer prompt" do
    found = context_with("needs" => " tell me when the merge is done ", "suggestedReply" => "the merge is finished, go ahead")
    expect(found).to include(needs: "tell me when the merge is done", suggested: "the merge is finished, go ahead")
  end

  it "carries an empty suggestion when Claude Code offered none" do
    expect(context_with("needs" => "pick a branch")).to include(suggested: "")
  end

  it "reads a live job that waits on a person as blocked, not done" do
    job("s1", "blocked", needs: "confirm the retry")
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

  def throughput(finished, open_work = [])
    data = { ci_runs: { unknown: "x" }, finished: finished, open_work: open_work }
    tiles = Hecks::Adapters::PipelineBoard::Metrics.tiles(data, now)
    tiles.find { |tile| tile[:id] == "throughput" }
  end

  it "asks for attention when nothing finished in the day while Work items wait in the plan" do
    stale = finished(["2026-10-31T19:00:00Z"])
    expect(throughput(stale, [{ status: "planned" }, { status: "started" }]))
      .to include(value: 0, state: "attention", detail: "last 2026-10-31 19:00:00 UTC; 1 planned")
  end

  it "stays ok with nothing finished when nothing waits in the plan" do
    expect(throughput([], [{ status: "started" }])).to include(value: 0, state: "ok", detail: "none finished yet; 0 planned")
  end

  it "lets a journal that cannot be read raise, so the board shows unknown instead of zero" do
    trace = ->(_count, _event) { raise Hecks::Adapters::PipelineBoard::Unavailable, "journal: no store" }
    journal = Hecks::Adapters::PipelineJournal.new(settings: { trace: trace, tap: File.join(dir, "none.jsonl"), ttl: 0 })
    expect { journal.named("WorkFinished", 200) }.to raise_error(Hecks::Adapters::PipelineBoard::Unavailable, /no store/)
  end

  it "counts the day's finished work from the events of that name, not from the recent window" do
    rows = finished(["2026-11-02T19:00:00Z", "2026-11-02T01:00:00Z", "2026-11-01T10:00:00Z"])
    expect(throughput(rows)).to include(value: 2, unit: "items / 24 h")
  end

  def working(sessions)
    tiles = Hecks::Adapters::PipelineBoard::Metrics.tiles({ ci_runs: { unknown: "x" }, sessions: sessions }, now)
    tiles.find { |tile| tile[:id] == "working" }
  end

  it "counts only sessions dispatched for a Work item against the cap, and says how many are alive" do
    live = [{ status: "busy", work_item: "a" }, { status: "busy", work_item: "" }, { status: "blocked", work_item: "" },
            { status: "done", work_item: "b" }]
    expect(working(live)).to include(value: 1, unit: "of 8", detail: "3 sessions alive, 1 blocked on you; load unknown")
  end

  it "says unknown when the journal could not be read" do
    expect(throughput({ unknown: "no store" })).to include(state: "unknown", detail: "unknown: no store")
  end
end
