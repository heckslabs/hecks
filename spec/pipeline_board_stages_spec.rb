# frozen_string_literal: true

require "spec_helper"
require_relative "support/pipeline_board_world"

# The PipelineBoard queries over stub ports: each stage answers from its reader, and a reader that
# fails gives `unknown: <reason>` for its stage while every other stage still answers.
RSpec.describe Hecks::Adapters::PipelineStages do
  include PipelineBoardWorld

  let(:base) { Dir.mktmpdir("board") }
  let(:gh) { canned_gh([run("b", 2, conclusion: "failure", minutes: 5), run("a", 1)]) }

  after { FileUtils.rm_rf(base) }

  def jobs_reader
    dir = File.join(base, "jobs")
    job_dir(dir, "s1", "working", "building")
    Hecks::Adapters::PipelineJobs.new(settings: { jobs_dir: dir, agents: -> { [] }, now: -> { Time.now } })
  end

  def fill_reader
    preview = { cap: 8, load: 1.0, limit: 12.0, would_start: [], skipped: [] }
    instance_double(Hecks::Adapters::PipelineFill, preview: preview)
  end

  def readers(overrides = {})
    work = repo_one_ahead(base)
    { github:  Hecks::Adapters::PipelineGitHub.new(settings: { gh: gh, ttl: 0 }),
      git:     Hecks::Adapters::PipelineGit.new(root: work, settings: { train: work, ttl: 0 }),
      tickets: Hecks::Adapters::PipelineTickets.new(settings: { work_items: work_items, landings: [] }),
      jobs:    jobs_reader,
      journal: instance_double(Hecks::Adapters::PipelineJournal, recent: [], named: [], landed_times: {}, promotions: [],
                                                                   cycle_events: []),
      fill:    fill_reader }.merge(overrides)
  end

  def board(overrides = {})
    described_class.new(root: base, settings: { readers: readers(overrides), now: -> { PipelineBoardWorld::NOW } })
  end

  def stage(name, overrides = {}) = board(overrides).state[:stages].find { |row| row[:name] == name }

  it "answers a row for every stage of the pipeline", :aggregate_failures do
    names = board.state[:stages].map { |row| row[:name] }
    expect(names).to eq(["Work items", "Sessions", "Local main", "Train", "CI", "Promote", "Release"])
  end

  it "counts the Work items by status" do
    expect(stage("Work items")).to include(count: "1/1/1")
  end

  it "counts the commits local main is ahead of origin/main" do
    expect(stage("Local main")).to include(count: "1", state: "attention")
  end

  it "says which commit local main is, whether it was gated, and what changed" do
    expect(stage("Local main")[:detail]).to match(/local main \h+, 1 ahead.*tests: quick gate not recorded.*changed: /)
  end

  it "reads the newest CI run as failed with its wall minutes" do
    expect(stage("CI")[:detail]).to include("failure", "5.0 min")
  end

  it "says stable has caught up with origin/main" do
    expect(stage("Promote")).to include(count: "0", state: "ok")
  end

  it "gives unknown with the reason for a stage whose port fails, and answers the rest", :aggregate_failures do
    broken = ->(*) { raise Hecks::Adapters::PipelineBoard::Unavailable, "gh is not installed" }
    ci = stage("CI", github: Hecks::Adapters::PipelineGitHub.new(settings: { gh: broken, ttl: 0 }))
    expect(ci).to include(state: "unknown", detail: "unknown: gh is not installed")
  end

  it "keeps answering the other stages when a port fails" do
    broken = ->(*) { raise Hecks::Adapters::PipelineBoard::Unavailable, "down" }
    rows = board(github: Hecks::Adapters::PipelineGitHub.new(settings: { gh: broken, ttl: 0 })).state[:stages]
    expect(rows.count { |row| row[:state] != "unknown" }).to be >= 4
  end
end
