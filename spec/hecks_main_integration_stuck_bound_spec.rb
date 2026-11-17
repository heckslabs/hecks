require "spec_helper"
require "json"

# A MainIntegration run that stands in one stage past its bound is parked in needs_human with the
# reason, and the line it held is free. The age is read from the tap's lines and the bound from the
# Tickets world, so the clock and the lines are stood in and the domain is in Memory.
RSpec.describe Hecks::Adapters::MainIntegration::Stale do
  let(:now) { Time.utc(2026, 11, 17, 12, 0, 0) }
  let(:stuck) { "a" * 40 }
  let(:later) { "b" * 40 }

  before(:all) { @hecks = boot_hecks_in_memory }

  before do
    @hecks.registry.saga_instances["MainIntegration"].clear
    described_class.stand_in(clock: -> { now })
  end

  after { described_class.stand_in }

  def registry = @hecks.registry

  def seed(sha, state)
    memory = { landed: { value: sha } }
    registry.saga_instances["MainIntegration"][sha] = { state: state, memory: memory, completed_compensations: [] }
  end

  def tapped(sha, event, minutes_ago)
    { "kind" => "event", "event" => event, "links" => { "landed" => sha }, "at" => (now - (minutes_ago * 60)).iso8601 }
  end

  def hear(*lines) = described_class.stand_in(lines: -> { lines }, clock: -> { now })

  def park = described_class.new(registry).park(Hecks::Adapters::MainIntegration::Runs.new(registry).all)

  def stage(sha) = Hecks::Adapters::MainIntegration::Runs.new(registry).find(sha).state

  it "parks a run past its bound with the stage, the age and what it waited for", :aggregate_failures do
    seed(stuck, "ci_running")
    hear(tapped(stuck, "MainPushed", 120))
    expect(park.first).to include("stalled in ci_running for 120 min (bound 90)", "CI on the train pull request")
    expect(stage(stuck)).to eq("needs_human")
  end

  it "leaves a run within its bound untouched", :aggregate_failures do
    seed(stuck, "ci_running")
    hear(tapped(stuck, "MainPushed", 80))
    expect(park).to eq([])
    expect(stage(stuck)).to eq("ci_running")
  end

  it "frees the line for a later run once the stuck one is parked" do
    seed(stuck, "pushed")
    seed(later, "verified")
    hear(tapped(stuck, "MainPushed", 50))
    park
    expect(Hecks::Adapters::MainIntegration::Runs.new(registry).in_flight(except: later)).to eq([])
  end

  it "never takes a run with no tap line for its stage for stale" do
    seed(stuck, "boarding")
    hear(tapped(stuck, "MainPushed", 500))
    expect(park).to eq([])
  end

  { "verifying" => ["MainVerificationStarted", 61], "reverifying" => ["MainVerificationStarted", 61],
    "boarding" => ["MainBoardingStarted", 31], "pushed" => ["MainPushed", 46],
    "merged" => ["TrainMergeSeen", 91] }.each do |state, (event, minutes)|
    it "parks a #{state} run after the world's bound for it" do
      seed(stuck, state)
      hear(tapped(stuck, event, minutes))
      park
      expect(stage(stuck)).to eq("needs_human")
    end
  end
end
