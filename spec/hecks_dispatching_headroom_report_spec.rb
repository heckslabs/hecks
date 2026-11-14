require "spec_helper"
require "hecks/hecks/adapters/dispatching"

# The fill's report says the room the load has, beside the cap, and the load a session costs.
RSpec.describe Hecks::Adapters::Dispatching, "#choose headroom clause" do
  # Idle near 2.5, and 7 sessions standing the load at 13.7: about 1.6 a session.
  LOADS = (([2.4, 2.5, 2.6, 2.5] * 3) + ([13.6, 13.7, 13.8, 13.7] * 3)).freeze

  def item(key) = described_class::Plan::Item.new(key: key, title: key, detail: "", area: [key])

  def report(loads)
    items = instance_double(described_class::WorkItems, planned: [item("a")], started: [], runs: {}, lessons: [])
    adapter = described_class.new(settings: { load: -> { 5.0 }, cpus: 8, work_items: items, loads: loads })
    adapter.choose(repo: "/repo", confirm: { value: false })[:report][:value]
  end

  it "says the room beside the cap and the load one session costs" do
    expect(report(LOADS)).to match(/; headroom \d+ of cap \d+ \(\d+\.\d load per session\);/)
  end

  it "says unread, with no cost, when no reading is recorded" do
    expect(report([])).to include("headroom unread of cap")
  end
end
