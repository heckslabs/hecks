# frozen_string_literal: true

require "spec_helper"
require "json"
require "hecks/pipeline_board/adapters/pipeline_github"

# The first read of the board: a run that succeeded has no failed job, so its jobs are never fetched.
RSpec.describe Hecks::Adapters::PipelineGitHub do
  def run(id, conclusion, status = "completed")
    { "databaseId" => id, "headSha" => "abcdef123", "startedAt" => "2026-11-03T10:00:00Z",
      "updatedAt" => "2026-11-03T10:05:00Z", "conclusion" => conclusion, "status" => status }
  end

  def adapter(runs, jobs: {}, calls: [])
    gh = lambda do |*args|
      calls << args
      raise Hecks::Adapters::PipelineBoard::Unavailable, "no jobs" if args[0..1] == %w[run view] && !jobs.key?(args[2])

      args[0..1] == %w[run list] ? runs : { "jobs" => jobs[args[2]] }
    end
    described_class.new(settings: { gh: gh, ttl: 0 })
  end

  def views(calls) = calls.select { |args| args[0..1] == %w[run view] }

  def failed_of(subject) = JSON.parse(subject.ci_runs[:text]).map { |row| row["failed_jobs"] }

  it "makes no jobs call for a successful or skipped run", :aggregate_failures do
    calls = []
    expect(failed_of(adapter([run(1, "success"), run(2, "skipped")], calls: calls))).to eq([0, 0])
    expect(views(calls)).to be_empty
  end

  it "makes exactly one jobs call for a failed run and counts its failed jobs", :aggregate_failures do
    calls = []
    jobs = { "7" => [{ "conclusion" => "failure" }, { "conclusion" => "success" }] }
    subject = adapter([run(7, "failure")], jobs: jobs, calls: calls)
    expect(failed_of(subject)).to eq([1])
    expect(views(calls).size).to eq(1)
  end

  it "does not fetch a settled run twice", :aggregate_failures do
    calls = []
    subject = adapter([run(7, "failure")], jobs: { "7" => [{ "conclusion" => "failure" }] }, calls: calls)
    2.times { subject.ci_runs }
    expect(views(calls).size).to eq(1)
  end

  def saved_adapter(path, calls)
    gh = lambda do |*args|
      calls << args
      args[0..1] == %w[run list] ? [run(7, "failure")] : { "jobs" => [{ "conclusion" => "failure" }] }
    end
    described_class.new(settings: { gh: gh, ttl: 0, settled_path: path })
  end

  it "reads a settled count from the file after a restart", :aggregate_failures do
    in_tmp("board", "settled.json") do |path|
      calls = restarted_twice(path)
      expect(views(calls).size).to eq(1)
      expect(JSON.parse(File.read(path))).to eq("7" => 1)
    end
  end

  def in_tmp(*parts) = Dir.mktmpdir { |dir| yield File.join(dir, *parts) }

  def restarted_twice(path)
    [].tap { |calls| 2.times { saved_adapter(path, calls).ci_runs } }
  end

  it "treats an unreadable file as a miss", :aggregate_failures do
    Dir.mktmpdir do |dir|
      path = File.join(dir, "settled.json")
      File.write(path, "not json")
      expect(failed_of(saved_adapter(path, []))).to eq([1])
    end
  end

  it "does not fail when the file cannot be written" do
    expect(failed_of(saved_adapter("/dev/null/x/settled.json", []))).to eq([1])
  end

  it "reports nil, not zero, for a failed run whose jobs are not listed" do
    expect(failed_of(adapter([run(9, "cancelled")]))).to eq([nil])
  end
end
