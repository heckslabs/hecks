require "spec_helper"
require "hecks/hecks/adapters/main_integration"
require "json"

# A MainIntegration run whose stage has no tap line is parked by the age of its landed commit once
# that age passes the stage's bound, and the line it held is free for the next verified landing. A
# run is never taken for stale when the tap itself could not be read.
RSpec.describe Hecks::Adapters::MainIntegration::Stale do
  let(:now) { Time.utc(2026, 11, 21, 12, 0, 0) }
  let(:stuck) { "a" * 40 }
  let(:later) { "b" * 40 }

  before(:all) { @hecks = boot_hecks_in_memory }

  before { @hecks.registry.saga_instances["MainIntegration"].clear }

  after { described_class.stand_in }

  def registry = @hecks.registry

  def seed(sha, state)
    memory = { landed: { value: sha } }
    registry.saga_instances["MainIntegration"][sha] = { state: state, memory: memory, completed_compensations: [] }
  end

  def tapped(sha, event, minutes_ago)
    { "kind" => "event", "event" => event, "links" => { "landed" => sha }, "at" => (now - (minutes_ago * 60)).iso8601 }
  end

  def hear(lines, committed_minutes_ago)
    described_class.stand_in(lines: -> { lines }, clock: -> { now },
                             committed: ->(_run) { now - (committed_minutes_ago * 60) })
  end

  def runs = Hecks::Adapters::MainIntegration::Runs.new(registry)

  def park = described_class.new(registry).park(runs.all)

  it "parks a run with no tap line once its landed commit is older than the stage's bound", :aggregate_failures do
    seed(stuck, "ci_running")
    hear([], 5 * 24 * 60)
    expect(park.first).to include("stalled in ci_running", "age of its landed commit", "CI on the train pull request")
    expect(runs.find(stuck).state).to eq("needs_human")
  end

  it "leaves a run with no tap line whose landed commit is within the bound" do
    seed(stuck, "ci_running")
    hear([], 30)
    expect(park).to eq([])
  end

  it "reads the tap line rather than the commit when the stage has one", :aggregate_failures do
    seed(stuck, "ci_running")
    hear([tapped(stuck, "MainPushed", 10)], 5 * 24 * 60)
    expect(park).to eq([])
    expect(runs.find(stuck).state).to eq("ci_running")
  end

  it "never takes a run for stale when the tap could not be read" do
    seed(stuck, "ci_running")
    described_class.stand_in(lines: -> {}, clock: -> { now }, committed: ->(_run) { now - (5 * 24 * 3600) })
    expect(park).to eq([])
  end

  it "lets the next verified landing board once the aged run is parked" do
    seed(stuck, "ci_running")
    seed(later, "verified")
    hear([], 5 * 24 * 60)
    park
    expect(runs.in_flight(except: later)).to eq([])
  end
end
