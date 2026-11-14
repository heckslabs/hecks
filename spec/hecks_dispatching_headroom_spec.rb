require "spec_helper"
require "hecks/hecks/adapters/dispatching"

# A fill starts as many work items as the load has room for, judged from the load each started
# session costs in the recent readings, and never more than the stagger or the cap allows.
RSpec.describe Hecks::Adapters::Dispatching::Headroom do
  # Idle near 2.5, and 7 sessions standing the load at 13.7: about 1.6 a session.
  IDLE_THEN_BUSY = (([2.4, 2.5, 2.6, 2.5] * 3) + ([13.6, 13.7, 13.8, 13.7] * 3)).freeze

  def headroom(loads, started:, load:) = described_class.new(loads: loads, started: started, load: load, max_load: 10.0)

  def item(key) = Hecks::Adapters::Dispatching::Plan::Item.new(key: key, title: key, detail: "", area: [key])

  def plan(room, **limits)
    items = %w[a b c d].map { |key| item(key) }
    Hecks::Adapters::Dispatching::Plan.new(items, [], cap: 7, load: 3.0, max_load: 10.0, frozen: [], headroom: room, **limits)
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

  it "starts no more than the room, and no more than the stagger", :aggregate_failures do
    expect(plan(1).chosen.map(&:key)).to eq(%w[a])
    expect(plan(9).chosen.map(&:key)).to eq(%w[a b])
  end

  it "holds the rest as a load wait the clock's beat watches", :aggregate_failures do
    made = plan(1)

    expect(made.skipped.first.reason).to start_with("skipped: load headroom 1")
    expect(made).to be_held_by_machine
  end

  it "does not hold the fix of a red main", :aggregate_failures do
    made = plan(0, exempt: ->(entry) { entry.key == "a" })

    expect(made.chosen.map(&:key)).to eq(%w[a])
    expect(made.skipped.size).to eq(3)
  end
end
