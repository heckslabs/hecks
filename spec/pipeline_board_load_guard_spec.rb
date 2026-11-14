# frozen_string_literal: true

require "spec_helper"
require "hecks/pipeline_board/adapters/pipeline_web"
require_relative "support/pipeline_board_world"
require_relative "support/no_child_process"

# The board adds no load to a loaded machine: the load is read with no child, and while it is
# above the limit a reader starts no program, so a whole state is built without one.
RSpec.describe Hecks::Adapters::PipelineBoard::LoadGuard do
  include PipelineBoardWorld
  include NoChildProcess

  let(:base) { Dir.mktmpdir("board-guard") }
  let(:probe) { Hecks::Adapters::PipelineBoard::Probe }
  let(:unavailable) { Hecks::Adapters::PipelineBoard::Unavailable }

  after do
    described_class.shared = nil
    FileUtils.rm_rf(base)
  end

  def guard(load, limit: 10.0) = described_class.new(limit: -> { limit }, load: -> { load }, now: -> { PipelineBoardWorld::NOW })

  def stand(load) = described_class.shared = guard(load)

  def stand_ins
    quiet = instance_double(Hecks::Adapters::PipelineJournal, recent: [], named: [], landed_times: {}, promotions: [],
                                                                cycle_events: [], stopped_times: {}, health_events: [])
    { journal: quiet, tickets: Hecks::Adapters::PipelineTickets.new(settings: { work_items: work_items, landings: [] }),
      boots: Hecks::Adapters::PipelineBoots.new(settings: { entries: ->(_date) { [] } }) }
  end

  # A board whose GitHub, Git, Jobs, Disk and Fill readers are the real ones, each with the
  # program it would run.
  def board
    jobs = Hecks::Adapters::PipelineJobs.new(settings: { jobs_dir: File.join(base, "jobs") })
    Hecks::Adapters::PipelineStages.new(root: base, settings: { readers: stand_ins.merge(jobs: jobs) })
  end

  it "reads the machine's load with no child process", :aggregate_failures do
    load = nil
    expect(children_started { load = described_class.reading }).to be_empty
    expect(load).to be > 0.0
  end

  it "is loaded above the limit and not at it", :aggregate_failures do
    expect(guard(10.1).loaded?).to be(true)
    expect(guard(10.0).loaded?).to be(false)
  end

  it "says the load, the limit and since when, only while loaded", :aggregate_failures do
    expect(guard(12.34).standing).to eq(load: 12.3, limit: 10.0, since: "2026-11-02T20:00:00Z")
    expect(guard(2.0).standing).to be_nil
  end

  it "starts no program for a reader while the machine is loaded", :aggregate_failures do
    stand(39.0)
    refused = -> { expect { probe.run("git", "status") }.to raise_error(unavailable, /git not run: load 39.0/) }
    expect(children_started(&refused)).to be_empty
  end

  it "runs a reader's program when the machine is not loaded" do
    stand(2.0)
    expect(probe.run("echo", "ran").strip).to eq("ran")
  end

  it "runs a step a person asked for on a loaded machine" do
    stand(39.0)
    expect(Hecks::Adapters::PipelineBoard::Actions.launcher(base, 5).call("echo", "ran").strip).to eq("ran")
  end

  it "builds a whole state on a loaded machine without starting a process", :aggregate_failures do
    stand(39.0)
    state = nil
    expect(children_started { state = board.state }).to be_empty
    expect(state[:load_guard]).to include(load: 39.0, limit: 10.0)
  end

  it "has the boots reader read the load with no child process" do
    boots = Hecks::Adapters::PipelineBoots.new(settings: { entries: ->(_date) { [] } })
    expect(children_started { boots.today }).to be_empty
  end
end
