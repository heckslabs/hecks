# frozen_string_literal: true

require "spec_helper"
require "json"
require "hecks/pipeline_board/adapters/pipeline_github"

# Flakes on train pull requests, projected from the recorded runs of the train lane: what failed
# on an earlier attempt of a run that a later attempt of the same run passed. GitHub is never asked.
RSpec.describe Hecks::Adapters::PipelineGitHub, "#train_flakes" do
  let(:today) { Time.now.utc.iso8601 }
  let(:failed_jobs) { JSON.generate([{ name: "rspec_shard (3)", minutes: 4.0, conclusion: "failure" }]) }

  def record(id, attempt, conclusion, jobs: "[]", pushed: today)
    { sighting: "#{id}-#{attempt}-done", ci_run: id.to_s, attempt: attempt, state: "completed", lane: "train",
      commit: "abc1234", branch: "train/main-#{id}", conclusion: conclusion, pushed_at: pushed, started_at: "",
      wall_minutes: 1.0, failed_jobs: 0, jobs: jobs, url: "https://gh/runs/#{id}" }
  end

  # One run that failed attempt 1 on `failed_jobs` and passed attempt 2.
  def flaked(id, **) = [record(id, 1, "failure", jobs: failed_jobs, **), record(id, 2, "success", **)]

  def adapter(*records)
    seats = Struct.new(:rows) { def records(_domain, _name) = rows }.new(records.flatten)
    described_class.new(settings: { gh: ->(*) { raise "gh asked" }, seats: -> { seats }, ttl: 0 })
  end

  def flakes(subject) = JSON.parse(JSON.generate(subject.flakes))

  it "answers each flake as a Flake row, with its branches and how far back the runs reach" do
    row = adapter(flaked(1)).train_flakes.first
    expect(row).to include(item: "rspec_shard (3)", kind: "job", count: 1, branches: "train/main-1", reaches_back: today)
  end

  it "lists the job that failed attempt 1 and passed on the rerun once", :aggregate_failures do
    row = flakes(adapter(flaked(1)))["flakes"]
    expect(row.map { |f| [f["item"], f["kind"], f["count"]] }).to eq([["rspec_shard (3)", "job", 1]])
    expect(row.first["prs"].first["branch"]).to eq("train/main-1")
  end

  it "counts a job once per run and once more for another run" do
    expect(flakes(adapter(flaked(1), flaked(2)))["flakes"].first["count"]).to eq(2)
  end

  it "does not count a run that never passed (a recurring failure)" do
    expect(flakes(adapter(record(1, 1, "failure", jobs: failed_jobs), record(1, 2, "failure")))["flakes"]).to eq([])
  end

  it "does not count a run that passed first time" do
    expect(flakes(adapter(record(1, 1, "success")))["flakes"]).to eq([])
  end

  it "leaves out a run older than 14 days" do
    expect(flakes(adapter(flaked(1, pushed: "2020-01-01T00:00:00Z")))["flakes"]).to eq([])
  end

  it "counts a rerun whose attempt 1 was never seen done as unreadable, not as no flake", :aggregate_failures do
    doc = flakes(adapter(record(1, 2, "success"), flaked(2)))
    expect([doc["unreadable"], doc["flakes"].first["count"]]).to eq([1, 1])
  end

  it "counts a failed attempt recorded without its jobs as unreadable" do
    expect(flakes(adapter(record(1, 1, "failure", jobs: ""), record(1, 2, "success")))["unreadable"]).to eq(1)
  end

  it "says how far back the runs reach" do
    expect(flakes(adapter(flaked(1)))["reaches_back"]).to eq(today)
  end

  it "says no train run is recorded when none is held" do
    expect { adapter.train_flakes }.to raise_error(Hecks::Adapters::PipelineBoard::Unavailable, /no train CI run/)
  end
end
