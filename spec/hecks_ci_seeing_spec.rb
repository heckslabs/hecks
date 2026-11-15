# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

require "hecks/hecks/adapters/ci_seeing"
require "hecks/hecks/adapters/main_integration/kept_rows"

# `CiLook` asks which CI runs GitHub lists in a state no record holds. The adapter reads `gh`, keys
# each run by its id, attempt and whether it was going or done, and reads the jobs of a completed
# run before it answers it.
RSpec.describe Hecks::Adapters::CiSeeing do
  let(:folder) { Dir.mktmpdir("ci-seeing") }
  let(:asked) { [] }
  let(:runs) do
    [{ "databaseId" => 7, "attempt" => 1, "headSha" => "abc1234", "headBranch" => "main", "status" => "completed",
       "conclusion" => "failure", "startedAt" => "2026-11-14T12:00:00Z", "updatedAt" => "2026-11-14T12:03:00Z" },
     { "databaseId" => 8, "attempt" => 2, "headSha" => "def5678", "headBranch" => "main", "status" => "in_progress" }]
  end
  let(:jobs) do
    { "jobs" => [{ "name" => "rspec", "conclusion" => "failure", "startedAt" => "2026-11-14T12:00:00Z",
                   "completedAt" => "2026-11-14T12:02:00Z", "url" => "https://example.test/job" }] }
  end

  after { FileUtils.rm_rf(folder) }

  def answer(args)
    asked << args.first(2)
    return jobs if args[1] == "view"

    args.include?("pull_request") ? [] : runs
  end

  def seeing(now: Time.utc(2026, 11, 14, 13))
    pace = described_class::Pace.new(path: File.join(folder, "look.json"), now: -> { now })
    described_class.new(settings: { gh: ->(*args) { answer(args) }, pace: pace })
  end

  it "answers a run still going and a completed one, each keyed by run, attempt and phase" do
    expect(seeing.unrecorded(run: "look-1").map { |row| row[:sighting] }).to contain_exactly("8-2-going", "7-1-done")
  end

  it "reads a completed run's jobs: how many failed, its wall time and the jobs as JSON", :aggregate_failures do
    done = seeing.unrecorded(run: "look-1").find { |row| row[:ci_run] == "7" }
    expect(done).to include(lane: "main", conclusion: "failure", wall_minutes: 3.0, failed_jobs: 1, id: "look-1")
    expect(JSON.parse(done[:jobs])).to eq([{ "name" => "rspec", "minutes" => 2.0, "conclusion" => "failure",
                                             "url" => "https://example.test/job" }])
  end

  it "asks GitHub once while a listing stands, so a beat within the pace lists nothing again" do
    seeing.unrecorded(run: "look-1")
    seeing(now: Time.utc(2026, 11, 14, 13, 1)).unrecorded(run: "look-2")
    expect(asked.count { |args| args == %w[run list] }).to eq(2)
  end

  it "asks again once the pace has passed" do
    seeing.unrecorded(run: "look-1")
    seeing(now: Time.utc(2026, 11, 14, 13, 5)).unrecorded(run: "look-2")
    expect(asked.count { |args| args == %w[run list] }).to eq(4)
  end

  it "keeps only the train's branches of the pull request runs" do
    pulls = { 9 => "train/main-abc", 10 => "x" }.map { |id, branch| runs.first.merge("databaseId" => id, "headBranch" => branch) }
    listing = described_class::Listing.new(->(*args) { args.include?("pull_request") ? pulls : [] })
    expect(listing.rows.map { |row| [row[:ci_run], row[:lane]] }).to eq([%w[9 train]])
  end

  it "declares the record a kept aggregate, so a run noted by one beat is read by the next" do
    rows = Hecks::Adapters::MainIntegration::KeptRows.from_registry(boot_hecks_in_memory.registry)
    expect(rows.map { |row| row[:aggregate] }).to include("CiRunRecord")
  end
end
