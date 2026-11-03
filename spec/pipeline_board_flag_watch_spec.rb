require "spec_helper"
require "hecks/pipeline_board/adapters/pipeline_web"

# While the board serves, it keeps main's red flag in step with CI: once per newly completed run it
# asks `RedFlag.sync!` through the launcher, never twice for one run, never for a run still going,
# never when the world sets no cadence, and never from an HTTP route.
RSpec.describe Hecks::Adapters::PipelineBoard::FlagWatch do
  let(:github) { instance_double(Hecks::Adapters::PipelineGitHub) }
  let(:synced) { [] }
  let(:watch) { described_class.new(github: github, every: 60, root: Dir.pwd, sync: -> { synced << :sync }) }

  def run(id, status: "completed") = { id: id, sha: "2dc207c", status: status, conclusion: "failure" }

  def world(**settings)
    Hecks::Bluebook::DSL::WorldBuilder.build("Hecks") { red_flag "Flag", **settings }
  end

  it "asks sync once when a completed run appears" do
    allow(github).to receive(:latest_run).and_return(run(41_540_218_609))
    watch.tick
    expect(synced.size).to eq(1)
  end

  it "does not ask again for the run it already acted on" do
    allow(github).to receive(:latest_run).and_return(run(41_540_218_609))
    2.times { watch.tick }
    expect(synced.size).to eq(1)
  end

  it "asks again for the next completed run" do
    allow(github).to receive(:latest_run).and_return(run(41_540_218_609), run(41_543_631_668))
    2.times { watch.tick }
    expect(synced.size).to eq(2)
  end

  it "leaves a run still in progress alone" do
    allow(github).to receive(:latest_run).and_return(run(41_545_950_228, status: "in_progress"))
    watch.tick
    expect(synced).to be_empty
  end

  it "waits out a GitHub read that fails" do
    allow(github).to receive(:latest_run).and_raise(Hecks::Adapters::PipelineBoard::Unavailable, "gh run list: 502")
    expect { watch.tick }.not_to raise_error
  end

  it "reads its cadence from the world's red_flag setting, and is off without one", :aggregate_failures do
    registry = instance_double(Hecks::Runtime::Registry, world: world(board_sync_seconds: 60))
    expect(described_class.cadence(registry)).to eq(60)
    expect(described_class.cadence(nil)).to eq(0)
    expect(described_class.new(github: github, every: 0, root: Dir.pwd, sync: -> {}).on?).to be(false)
  end

  it "is reachable from no route of the board" do
    expect(Hecks::Adapters::PipelineBoard::Server::ROUTES.grep(/sync|flag/)).to be_empty
  end

  it "is built by the board with the world's cadence and started with the server" do
    stages = instance_double(Hecks::Adapters::PipelineStages, state: {})
    settings = { stages: stages, wiring: nil, github: github, flag_sync: 0, background: false }
    expect(Hecks::Adapters::PipelineWeb.new(settings: settings).flag_watch.on?).to be(false)
  end
end
