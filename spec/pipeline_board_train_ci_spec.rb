# frozen_string_literal: true

require "spec_helper"
require "json"
require "hecks/pipeline_board/adapters/pipeline_github"

# CI on train pull requests, from the recorded runs of the `train` lane: first attempts only, so a
# rerun's wall time is never taken for a run's, and a failed run names its failed jobs.
RSpec.describe Hecks::Adapters::PipelineGitHub, "#train_ci_runs" do
  def record(id, attempt: 1, **fields)
    { sighting: "#{id}-#{attempt}-done", ci_run: id.to_s, attempt: attempt, state: "completed", lane: "train",
      commit: "abcdef123", branch: "train/main-abc", conclusion: "success", pushed_at: "2026-11-03T10:0#{id}:00Z",
      started_at: "", wall_minutes: 5.0, failed_jobs: 0, jobs: "[]", url: "" }.merge(fields)
  end

  def adapter(*records)
    seats = Struct.new(:rows) { def records(_domain, _name) = rows }.new(records)
    described_class.new(settings: { gh: ->(*) { raise "gh asked" }, seats: -> { seats }, ttl: 0 })
  end

  def rows(subject) = subject.train_ci_runs

  it "leaves out a rerun, whose wall time is not the run's", :aggregate_failures do
    found = rows(adapter(record(1), record(2), record(2, attempt: 3, wall_minutes: 40.0), record(9, lane: "main")))
    expect(found.map { |row| row[:id] }).to eq([1, 2])
    expect(found.last[:wall_minutes]).to eq(5.0)
  end

  it "shows the failed jobs of a failed run" do
    expect(rows(adapter(record(3, conclusion: "failure", failed_jobs: 1))).first[:failed_jobs]).to eq(1)
  end

  it "names the slowest job of the latest completed train run" do
    jobs = JSON.generate([{ name: "a", minutes: 1.0 }, { name: "b", minutes: 3.0 }])
    slow = adapter(record(4, jobs: jobs)).train_slowest_jobs
    expect(slow.map { |job| job[:name] }).to eq(%w[b a])
  end
end
