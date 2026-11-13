require "spec_helper"
require "time"
require "hecks/hecks/adapters/dispatching"
require_relative "support/agent_run_records"

# A yield records a kind, and the plan leaves a parked item out of a fill and says why.
RSpec.describe Hecks::Adapters::Dispatching::Parking do
  let(:now) { Time.utc(2026, 11, 9, 12, 0, 0) }
  let(:plan_class) { Hecks::Adapters::Dispatching::Plan }
  let(:taken) { "dispatch of a failed: [already_recorded] refused: run a is already recorded with other arguments" }

  def item(key, **parked) = plan_class::Item.new(key: key, title: "T", detail: "", area: [], **parked)

  def plan_of(items, runs = {})
    plan_class.new(items, [], cap: 5, load: 0.0, max_load: 8.0, frozen: [], now: now, runs: -> { runs })
  end

  it "classifies a taken run key, a missing Passage and anything else by the refusal", :aggregate_failures do
    expect(described_class.classify(taken, count: 1, now: now).name).to eq("already_recorded")
    expect(described_class.classify("no Passage with change.value \"x\"", count: 1, now: now).name).to eq("missing_passage")
    expect(described_class.classify("boom", count: 1, now: now).name).to eq("transient")
  end

  it "backs a transient yield off 5, 15 and 45 minutes and then holds at 45", :aggregate_failures do
    waits = [1, 2, 3, 4].map { |count| described_class.classify("boom", count: count, now: now).retry_at - now }

    expect(waits).to eq([300, 900, 2700, 2700])
  end

  it "parks a transient item until its retry time, and names it in the skipped list", :aggregate_failures do
    parked = item("a", yield_kind: "transient", retry_at: (now + 300).iso8601, yield_count: 1)
    plan = plan_of([parked])

    expect(plan.chosen).to be_empty
    expect(plan.skipped.first.reason).to start_with("parked: transient yield #1")
  end

  it "starts a transient item once its retry time has passed" do
    due = item("a", yield_kind: "transient", retry_at: (now - 1).iso8601, yield_count: 1)

    expect(plan_of([due]).chosen.map(&:key)).to eq(["a"])
  end

  it "parks an item whose run key is live and frees it when the run ends", :aggregate_failures do
    held = item("a", yield_kind: "already_recorded", yield_count: 1)

    expect(plan_of([held], "a" => { status: "started" }).skipped.first.reason).to include("run a is started")
    expect(plan_of([held], "a" => { status: "finished" }).chosen.map(&:key)).to eq(["a"])
  end

  it "does not count a parked item against the cap" do
    parked = item("a", yield_kind: "transient", retry_at: (now + 60).iso8601)
    plan = plan_class.new([parked, item("b")], [], cap: 1, load: 0.0, max_load: 8.0, frozen: [], now: now)

    expect(plan.chosen.map(&:key)).to eq(["b"])
  end

  describe "a run key that holds archived records" do
    include AgentRunRecords

    def runs_of(*records) = work_items_over(*records).runs

    it "is read from the record that holds the key, though an archive is listed after it", :aggregate_failures do
      runs = runs_of(run_record("a", "started"), run_record("a~1", "tidied"))

      expect(runs["a"][:status]).to eq("started")
      expect(plan_of([item("a")], runs).skipped.first.reason).to include("run a is started")
    end

    it "parks an already_recorded item behind the live run, whatever the archive says" do
      held = item("a", yield_kind: "already_recorded", yield_count: 1)

      expect(plan_of([held], runs_of(run_record("a", "started"), run_record("a~1", "finished"))).chosen).to be_empty
    end

    it "reads as ended when only an archive is left, so its item starts" do
      expect(plan_of([item("a")], runs_of(run_record("a~1", "tidied"))).chosen.map(&:key)).to eq(["a"])
    end

    it "starts the item in none of ten rolls while its run is live" do
      runs = runs_of(run_record("a", "started"), run_record("a~1", "tidied"))

      expect(Array.new(10) { plan_of([item("a")], runs).chosen }.flatten).to be_empty
    end
  end
end
