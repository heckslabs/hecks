# frozen_string_literal: true

require "spec_helper"
require_relative "support/pipeline_board_world"

# The Snapshot query over stub readers: the same state the page serves, drawn as text, with the
# open train pull requests and their check counts read from `gh pr list`.
RSpec.describe Hecks::Adapters::PipelineStages do
  include PipelineBoardWorld

  let(:base) { Dir.mktmpdir("board") }
  let(:rollup) { [{ "conclusion" => "SUCCESS" }, { "conclusion" => "FAILURE" }, { "state" => "PENDING" }] }
  let(:pulls) do
    [{ "number" => 7, "headRefName" => "train/main-abc", "statusCheckRollup" => rollup },
     { "number" => 8, "headRefName" => "feature/x", "statusCheckRollup" => [] }]
  end

  after { FileUtils.rm_rf(base) }

  def gh(listing)
    canned = canned_gh([run("a", 1)])
    ->(*args) { args.first(2) == %w[pr list] ? listing.call : canned.call(*args) }
  end

  def jobs
    dir = File.join(base, "jobs")
    job_dir(dir, "s1", "working", "building")
    Hecks::Adapters::PipelineJobs.new(settings: { jobs_dir: dir, agents: -> { [] }, now: -> { Time.now } })
  end

  def idle_fill
    instance_double(Hecks::Adapters::PipelineFill, preview: { cap: 8, load: 1.0, limit: 12.0, would_start: [], skipped: [] })
  end

  def readers(listing)
    work = repo_one_ahead(base)
    { github: Hecks::Adapters::PipelineGitHub.new(settings: { gh: gh(listing), ttl: 0 }),
      git: Hecks::Adapters::PipelineGit.new(root: work, settings: { train: work, ttl: 0 }),
      tickets: Hecks::Adapters::PipelineTickets.new(settings: { work_items: work_items, landings: [] }),
      jobs: jobs, fill: idle_fill,
      journal: instance_double(Hecks::Adapters::PipelineJournal, recent: [], named: [], landed_times: {}, promotions: [],
                                                                   cycle_events: []) }
  end

  def board(listing = -> { pulls })
    described_class.new(root: base, settings: { readers: readers(listing), now: -> { PipelineBoardWorld::NOW } })
  end

  def panel(listing = -> { pulls }, **options) = board(listing).snapshot(**options)[:text]

  it "answers the panel as one text document" do
    expect(panel).to start_with("+- Pipeline board 2026-11-02T20:00:00Z")
  end

  it "lists the open train pull requests, and only those, with their check counts" do
    expect(panel.lines.grep(/#\d/).map(&:strip).join).to match(%r{#7 train/main-abc\s+3 checks: 1 passed, 1 failed, 1 pending})
  end

  it "does not list a pull request that is not on a train branch" do
    expect(panel).not_to include("#8")
  end

  it "takes its width and limit as value objects, as the query hands them", :aggregate_failures do
    lines = panel(width: { value: 100 }, limit: { value: 1 }).lines.map(&:chomp)
    expect(lines.map(&:length).uniq).to eq([100])
  end

  it "colours the rows when the colour value object says true" do
    expect(panel(colour: { value: "true" })).to include("\e[")
  end

  it "says unknown for the pull requests when gh cannot list them" do
    down = -> { raise Hecks::Adapters::PipelineBoard::Unavailable, "gh down" }
    expect(panel(down)).to include("unknown: gh down")
  end
end
