require "spec_helper"
require "hecks/hecks/adapters/dispatching"

# A started batch is one session: its members are batched out of the plan, so only the lead takes
# a place under the cap and other work still starts beside it.
RSpec.describe Hecks::Adapters::Dispatching::Plan, "#chosen" do
  def item(key, area) = described_class::Item.new(key: key, title: key, area: [area])

  def lead = described_class::Item.new(key: "a", title: "a", area: ["lib/x"], batched: %w[b c d e f])

  def plan(cap) = described_class.new([item("z", "lib/z")], [lead], cap: cap, load: 1.0, max_load: 10.0, frozen: [])

  it "counts a group of six as one session against the cap, so another item starts" do
    expect(plan(2).chosen.map(&:key)).to eq(%w[z])
  end

  it "holds the next item for the cap once the group's one session fills it" do
    expect(plan(1).skipped.map(&:reason).first).to include("cap")
  end
end
