# frozen_string_literal: true

require "spec_helper"
require "json"
require "hecks/pipeline_board/adapters/pipeline_github"

# CI on train pull requests: the runs of the `train/` branches, first attempts only, so a rerun's
# wall time is never taken for a run's, and a failed run names its failed jobs.
RSpec.describe Hecks::Adapters::PipelineGitHub, "#train_ci_runs" do
  def run(id, branch: "train/main-abc", attempt: 1, conclusion: "success", minutes: 5)
    { "databaseId" => id, "headSha" => "abcdef123", "headBranch" => branch, "attempt" => attempt,
      "startedAt" => "2026-11-03T10:00:00Z", "updatedAt" => "2026-11-03T10:#{format("%02d", minutes)}:00Z",
      "createdAt" => "2026-11-03T10:00:00Z", "conclusion" => conclusion, "status" => "completed" }
  end

  def adapter(runs, jobs: {}, calls: [])
    gh = lambda do |*args|
      calls << args
      args[0..1] == %w[run list] ? runs : { "jobs" => jobs.fetch(args[2], []) }
    end
    described_class.new(settings: { gh: gh, ttl: 0 })
  end

  def rows(subject) = JSON.parse(subject.train_ci_runs[:text])

  it "asks for pull request runs of the CI workflow" do
    calls = []
    adapter([], calls: calls).train_ci_runs
    expect(calls.first).to include("--event", "pull_request", "--workflow", "ci.yml")
  end

  it "leaves out a rerun, whose wall time is not the run's", :aggregate_failures do
    found = rows(adapter([run(1), run(2, attempt: 3, minutes: 40)]))
    expect(found.map { |row| row["id"] }).to eq([1])
    expect(found.first["wall_minutes"]).to eq(5.0)
  end

  it "leaves out runs of branches that are not train branches" do
    expect(rows(adapter([run(1), run(2, branch: "feature/x")])).size).to eq(1)
  end

  it "shows the failed jobs of a failed run" do
    jobs = { "3" => [{ "conclusion" => "failure" }, { "conclusion" => "success" }] }
    expect(rows(adapter([run(3, conclusion: "failure")], jobs: jobs)).first["failed_jobs"]).to eq(1)
  end

  it "names the slowest job of the latest completed train run", :aggregate_failures do
    jobs = { "4" => [{ "name" => "a", "startedAt" => "2026-11-03T10:00:00Z", "completedAt" => "2026-11-03T10:01:00Z" },
                     { "name" => "b", "startedAt" => "2026-11-03T10:00:00Z", "completedAt" => "2026-11-03T10:03:00Z" }] }
    slow = JSON.parse(adapter([run(4)], jobs: jobs).train_slowest_jobs[:text])
    expect(slow.map { |job| job["name"] }).to eq(%w[b a])
  end
end
