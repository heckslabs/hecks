# frozen_string_literal: true

require "spec_helper"
require "hecks/pipeline_board/adapters/pipeline_github"

# The board shows CI from the domain's `CiRunRecord` rows and never asks `gh` for it: with no
# record it says so, and a loaded machine or a board that has just restarted still shows CI.
RSpec.describe Hecks::Adapters::PipelineBoard::CiRecords do
  def record(sighting, **fields)
    run, attempt, phase = sighting.split("-")
    { sighting: sighting, ci_run: run, attempt: attempt.to_i, state: phase == "done" ? "completed" : "in_progress",
      lane: "main", commit: "abc1234def", branch: "main", conclusion: "", pushed_at: "2026-11-14T12:0#{run}:00Z",
      started_at: "", wall_minutes: 0.0, failed_jobs: 0, jobs: "", url: "" }.merge(fields)
  end

  def runtime_record(sighting, **fields)
    fields = record(sighting, **fields).merge(state: Struct.new(:value).new("completed"))
    aggregate = double(hecks_name: "CiRunRecord", identity_heads: [], identified_by: nil, attribute: nil)
    Hecks::Runtime::Instance.new(aggregate: aggregate, id: sighting, state: fields, hydrate: false)
  end

  let(:asked) { [] }
  let(:held) { [] }
  let(:unavailable) { Hecks::Adapters::PipelineBoard::Unavailable }

  def github
    seats = Struct.new(:rows) { def records(_domain, _name) = rows }.new(held)
    Hecks::Adapters::PipelineGitHub.new(settings: { gh: ->(*args) { (asked << args) && [] }, seats: -> { seats }, ttl: 0 })
  end

  def runs(reader = :ci_runs) = github.public_send(reader)

  it "says no run is recorded, and does not ask gh, when none is held", :aggregate_failures do
    expect { runs }.to raise_error(unavailable, /no main CI run is recorded yet/)
    expect(asked).to be_empty
  end

  it "reads the runs from the record without asking gh", :aggregate_failures do
    held.push(record("1-1-done", conclusion: "success", wall_minutes: 2.6), record("2-1-going"))
    expect(runs.map { |row| row.slice(:id, :sha, :status, :conclusion, :wall_minutes) })
      .to eq([{ id: 1, sha: "abc1234", status: "completed", conclusion: "success", wall_minutes: 2.6 },
              { id: 2, sha: "abc1234", status: "in_progress", conclusion: "", wall_minutes: 0.0 }])
    expect(asked).to be_empty
  end

  it "takes the newest record of a run: its latest attempt, done over going" do
    held.push(record("1-1-going"), record("1-1-done", conclusion: "failure"), record("1-2-done", conclusion: "success"))
    expect(runs.map { |row| row[:conclusion] }).to eq(["success"])
  end

  it "lists the train's runs by their first attempt, as a rerun's time is not the run's" do
    held.push(record("1-1-done", lane: "train", wall_minutes: 3.0), record("1-2-done", lane: "train", wall_minutes: 0.4))
    expect(runs(:train_ci_runs).map { |row| row[:wall_minutes] }).to eq([3.0])
  end

  it "reads the slowest jobs from the newest completed run's record" do
    jobs = JSON.generate([{ name: "fast", minutes: 0.5 }, { name: "slow", minutes: 2.5 }])
    held.push(record("1-1-done", jobs: jobs), record("2-1-going"))
    expect(runs(:slowest_jobs).map { |job| job[:name] }).to eq(%w[slow fast])
  end

  it "says no train run is recorded with its jobs when only main's are" do
    held.push(record("1-1-done", jobs: "[]"))
    expect { runs(:train_slowest_jobs) }.to raise_error(unavailable, /no completed train CI run/)
  end

  it "reads the status word of a runtime record whose state is a value object", :aggregate_failures do
    held.push(runtime_record("1-1-done", conclusion: "success"))
    expect(runs.map { |row| row[:status] }).to eq(["completed"])
    expect(JSON.generate(github.ci_runs)).not_to include("#<", ":sighting=>")
  end
end
