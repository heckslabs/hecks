require "spec_helper"
require "hecks/hecks/adapters/dispatching"

# The load the machine has room for, judged from the load each started session costs in the recent
# readings. A fill states it and holds no work item to it: the load limit and the cap stop a fill.
RSpec.describe Hecks::Adapters::Dispatching::Headroom do
  # Idle near 2.5, and 7 sessions standing the load at 13.7: about 1.6 a session.
  IDLE_THEN_BUSY = (([2.4, 2.5, 2.6, 2.5] * 3) + ([13.6, 13.7, 13.8, 13.7] * 3)).freeze

  def headroom(loads, started:, load:) = described_class.new(loads: loads, started: started, load: load, max_load: 10.0)

  def item(key) = Hecks::Adapters::Dispatching::Plan::Item.new(key: key, title: key, detail: "", area: [key])

  def plan(room, **limits)
    items = %w[a b c d].map { |key| item(key) }
    limits = { load: 3.0 }.merge(limits)
    Hecks::Adapters::Dispatching::Plan.new(items, [], cap: 7, max_load: 10.0, frozen: [], headroom: room, **limits)
  end

  it "reads the load one session costs from the idle load and the load now" do
    expect(headroom(IDLE_THEN_BUSY, started: 7, load: 5.0).per_session).to be_within(0.2).of(1.6)
  end

  it "has room for the sessions the load can still take, none at the limit", :aggregate_failures do
    expect(headroom(IDLE_THEN_BUSY, started: 7, load: 5.0).room).to eq(3)
    expect(headroom(IDLE_THEN_BUSY, started: 7, load: 10.0).room).to eq(0)
  end

  it "says no room at all with no reading, so the cap and the load limit alone apply" do
    expect(headroom([], started: 3, load: 5.0).room).to be_nil
  end

  it "takes the measured cost per session when fewer than two run" do
    expect(headroom(IDLE_THEN_BUSY, started: 1, load: 5.0).per_session).to eq(1.6)
  end

  it "holds nothing to the estimate while the load is under its limit", :aggregate_failures do
    expect(plan(0).chosen.map(&:key)).to eq(%w[a b c d])
    expect(plan(1).skipped).to be_empty
  end

  it "holds every item as a load wait the clock's beat watches once the load is over its limit", :aggregate_failures do
    made = plan(9, load: 12.0)

    expect(made.skipped.map(&:reason).uniq).to eq(["skipped: load 12.0 > 10.0"])
    expect(made).to be_held_by_machine
  end
end
