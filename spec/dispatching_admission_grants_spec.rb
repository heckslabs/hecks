# frozen_string_literal: true

require "spec_helper"
require_relative "support/os_level_readings"

# The ruling a fill makes just before a start, as the start's check (`WorkLimits.CheckCap`) reads
# it: kept once, for that work item alone, inside the ramp window.
RSpec.describe Hecks::Adapters::Dispatching::Admitting, "#admit!" do
  include OsLevelReadings

  let(:now) { Time.utc(2026, 11, 20, 14, 29, 0) }
  let(:beat) { { band: "short", headroom: 6879, floor: 3072, gap: 2048, age: 0, stale_after: 120, draw: 474 } }

  before { Hecks::Adapters::Dispatching::AdmissionGrants.clear! }

  def door(refusal)
    instance_double(Hecks::Adapters::Dispatching::SignalboxDoor, look: beat, setting: {}, refusal: refusal)
  end

  def admitting(refusal, at: now) = described_class.new(runs: {}, now: at, door: door(refusal))

  def planned(key) = Hecks::Adapters::Dispatching::Plan::Item.new(key: key, title: key, priority: "next")

  it "is kept by the start's check though the next beat would refuse" do
    admitting(nil).admit!(planned("tiles"))
    expect(admitting("only an urgent coder is admitted while pressure is short").reason(planned("tiles"))).to be_nil
  end

  it "is kept once: a second check reads its own beat" do
    admitting(nil).admit!(planned("tiles"))
    admitting("no room").reason(planned("tiles"))
    expect(admitting("no room").reason(planned("tiles"))).to include("no room")
  end

  it "leaves no grant when it refuses" do
    admitting("no room").admit!(planned("tiles"))
    expect(admitting("no room").reason(planned("tiles"))).to include("no room")
  end

  it "admits no other work item" do
    admitting(nil).admit!(planned("tiles"))
    expect(admitting("no room").reason(planned("rails"))).to include("no room")
  end

  it "lapses after the ramp window" do
    admitting(nil).admit!(planned("tiles"))
    expect(admitting("no room", at: now + 61).reason(planned("tiles"))).to include("no room")
  end

  it "holds a second start inside the ramp window by Signalbox's own given" do
    runs = { "first" => { started_at: (now - 5).iso8601 } }
    expect(described_class.new(runs: runs, now: now, door: door_at(1)).admit!(item)).to include("ramp step")
  end
end
