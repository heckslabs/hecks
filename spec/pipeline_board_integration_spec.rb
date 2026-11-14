# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "json"
require "hecks/pipeline_board/adapters/pipeline_stages"
require "hecks/pipeline_board/adapters/pipeline_web/tiles"

# The board's reading of the MainIntegration saga: each run's stored stage and the time of its
# last event, the runs parked for a person told apart, and no way to advance a run.
RSpec.describe Hecks::Adapters::PipelineIntegration do
  let(:now) { Time.utc(2026, 11, 14, 12, 0, 0) }
  let(:stages) { { run("a") => "ci_running", run("b") => "verified", run("c") => "needs_human", run("d") => "green" } }
  let(:board) { Hecks::Adapters::PipelineBoard }

  def run(letter) = letter * 40

  # A saga store holding one checkpoint per run, and one of another process manager.
  def saga_store(states)
    rows = states.map { |landed, stage| ["MainIntegration", landed, stage, {}, []] }
    Struct.new(:rows) { def each_saga = rows.each }.new(rows + [["BugCiWatch", "x", "watching", {}, []]])
  end

  def registry_over(store) = Struct.new(:store) { def saga_persistence(*) = store }.new(store)

  def store_over(sagas) = board::RegistryStore.new(registry: registry_over(sagas))

  def event(name, at, landed = nil)
    { aggregate: "Hecks::Integration", name: name, at: at, links: landed ? { "landed" => landed } : {} }
  end

  def log_rows
    [{ aggregate: "Hecks::SendTrain", name: "BoardingQueued", at: "2026-11-14T09:00:00Z", links: {} },
     event("MainVerified", "2026-11-14T10:30:00Z", run("b")),
     event("IntegrationAdvanced", "2026-11-14T11:40:00Z"),
     event("CiObservationStarted", "2026-11-14T11:58:00Z", run("a"))]
  end

  def journal(rows = log_rows)
    instance_double(Hecks::Adapters::PipelineJournal, integration_seen: board::IntegrationRuns.seen(rows))
  end

  def reading(states = stages, from = journal)
    described_class.new(store: store_over(saga_store(states)), journal: from, now: -> { now }).reading
  end

  def listed(landed) = reading[:runs].find { |listed| listed[:landed] == landed }

  def row(states = stages) = board::IntegrationRuns.row(reading(states), now)

  def tile(states = stages) = board::TileHtml.integration(row(states).merge(reading: reading(states)))

  describe "the reading" do
    it "counts the runs by the stage stored for each" do
      expect(reading[:stages]).to eq("ci_running" => 1, "verified" => 1, "needs_human" => 1, "green" => 1)
    end

    it "counts the runs being pushed or watched and those parked for a person", :aggregate_failures do
      expect(reading[:in_flight]).to eq(1)
      expect(reading[:needs_human]).to eq(1)
      expect(reading[:total]).to eq(4)
    end

    it "leaves out the checkpoints of another process manager" do
      expect(reading[:runs].map { |listed| listed[:landed] }).not_to include("x")
    end

    it "lists the runs that lately moved first, then a parked run, then the rest" do
      expect(reading[:runs].map { |listed| listed[:landed] }).to eq([run("a"), run("b"), run("c"), run("d")])
    end

    it "gives each stored stage one line, the parked stage first, with the time since any of its runs moved" do
      expect(reading[:by_stage].first(2)).to eq([{ stage: "needs_human", count: 1, minutes: nil, parked: true },
                                                 { stage: "ci_running", count: 1, minutes: 2, parked: false }])
    end

    it "says how far back the log's tail reaches, so a run with no event in it has waited at least that long" do
      expect(reading[:quiet_minutes]).to eq(180)
    end

    it "says how long ago a run's last event was recorded, so a run that waits shows its age" do
      expect(listed(run("b"))).to include(stage: "verified", minutes: 90)
    end

    it "gives no age for a run the log's tail holds no event of" do
      expect(listed(run("d"))[:minutes]).to be_nil
    end

    it "names the newest advance and how far back the log's tail reaches", :aggregate_failures do
      expect(reading[:last_advance]).to eq("2026-11-14T11:40:00Z")
      expect(reading[:log_since]).to eq("2026-11-14T09:00:00Z")
    end

    it "lists at most the integration_runs_shown setting" do
      many = (1..30).to_h { |index| [format("%040d", index), "green"] }
      expect(reading(many)[:runs].size).to eq(board::Rules.setting("integration_runs_shown"))
    end

    it "keeps the stored stages when the event log cannot be read" do
      unread = instance_double(Hecks::Adapters::PipelineJournal)
      allow(unread).to receive(:integration_seen).and_raise(board::Unavailable, "no log")
      expect(reading(stages, unread)[:stages]).to include("verified" => 1)
    end
  end

  describe "the strip's row" do
    it "fails the stage while a run is parked for a person" do
      expect(row).to include(name: "Integration", state: "failed", count: "1")
    end

    it "judges a run that waits by nothing: a verified run leaves the stage ok" do
      expect(row(run("b") => "verified")[:state]).to eq("ok")
    end

    it "says in its detail how many runs are stored in each stage and when the last advance was" do
      expect(row[:detail]).to include("1 parked for you", "last advance 20 min ago", "verified 1")
    end

    it "is unknown, with the reason, when the reading failed" do
      failed = board::IntegrationRuns.row({ unknown: "no store" }, now)
      expect(failed).to include(state: "unknown", detail: "unknown: no store")
    end
  end

  describe "the tile" do
    it "marks a parked run with an icon and words, not by colour alone" do
      expect(tile).to include("<td>#{"c" * 10}</td><td>✕ needs you (needs_human)</td><td>none for over 180 min</td>")
    end

    it "gives the parked stage its own line, marked the same way, with how many runs it holds" do
      expect(tile).to include("<td>✕ needs you (needs_human)</td><td>1</td>")
    end

    it "shows how long a stage's runs have waited: a verified run that nothing boards shows its age" do
      expect(tile).to include("<td>verified</td><td>1</td><td>90 min ago</td>")
    end

    it "shows each run's stage as the saga stored it, with the time since its last event" do
      expect(tile).to include("<td>#{"b" * 10}</td><td>verified</td><td>90 min ago</td>")
    end

    it "offers nothing to click, parked run or not" do
      expect(tile).not_to match(/data-resolve|clickable|<button|<form|<a /)
    end

    it "is drawn again when an Integration event is recorded" do
      tiles = board::Tiles.new(rows: board::Rules.rows("Tile"), renderers: {})
      expect(tiles.reading("Hecks::Integration")).to eq(["integration"])
    end
  end

  describe "the checkpoints, read through the registry's saga store" do
    let(:dir) { Dir.mktmpdir("board-sagas") }
    let(:aggregate) { boot_hecks_in_memory.registry.bluebook("Tickets").aggregate("Work") }

    after { FileUtils.rm_rf(dir) }

    def kept(adapter)
      adapter.save_saga(process_manager: "MainIntegration", correlation: run("a"), state: "verified", memory: { checkout: "/c" })
      adapter.save_saga(process_manager: "Other", correlation: "o", state: "started", memory: {})
      store_over(adapter).sagas("Hecks", "MainIntegration")
    end

    it "reads a Sqlite store's checkpoints" do
      adapter = Hecks::Adapters::Sqlite.new(aggregate: aggregate, settings: { database: "sagas.db", domain: "Hecks" }, root: dir)
      expect(kept(adapter)).to eq(run("a") => "verified")
    end

    it "reads a Heki store's checkpoints" do
      adapter = Hecks::Adapters::Heki.new(aggregate: aggregate, settings: { dir: dir, domain: "Hecks" })
      expect(kept(adapter)).to eq(run("a") => "verified")
    end

    it "answers no run for a domain that keeps no checkpoint" do
      expect(store_over(Hecks::Ports::Persistence::NULL_SAGA_STORE).sagas("Hecks", "MainIntegration")).to eq({})
    end

    it "says so when the registry resolves no saga store" do
      expect { board::RegistryStore.new(registry: nil).sagas("Hecks", "MainIntegration") }
        .to raise_error(board::Unavailable, /resolves no saga store/)
    end
  end

  describe "the event log's tail" do
    let(:dir) { Dir.mktmpdir("board-tap") }
    let(:log) { File.join(dir, "events.jsonl") }

    after { FileUtils.rm_rf(dir) }

    def line(event, at, links)
      JSON.generate("kind" => "event", "at" => at, "aggregate" => "Hecks::Integration", "event" => event, "links" => links)
    end

    def seen
      File.write(log, [line("MainVerified", "2026-11-14T10:00:00Z", { "landed" => run("b") }),
                       line("IntegrationAdvanced", "2026-11-14T10:01:00Z", {})].join("\n").concat("\n"))
      Hecks::Adapters::PipelineJournal.new(settings: { trace: ->(*) { { events: [] } }, tap: log, ttl: 0 }).integration_seen
    end

    it "gives each run's last event time and the newest advance", :aggregate_failures do
      expect(seen[:times]).to eq(run("b") => "2026-11-14T10:00:00Z")
      expect(seen[:advanced]).to eq("2026-11-14T10:01:00Z")
    end
  end

  describe "the board's code" do
    def files
      board_code = File.expand_path("../lib/hecks/pipeline_board", __dir__)
      Dir.glob(File.join(board_code, "**", "*")).select { |path| File.file?(path) }
    end

    it "names no advance of an integration run, so nothing in it can ask for one" do
      naming = files.select { |path| File.read(path).match?(/advance!|Integration::Advance|Integration\.advance|"Advance"/) }
      expect(naming).to eq([])
    end
  end
end
