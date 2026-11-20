require "spec_helper"
require "hecks/hecks/adapters/dispatching"

# A started batch is one session: its members wait for its lead and do not take places under the
# cap, so other work still starts beside it.
RSpec.describe Hecks::Adapters::Dispatching::Plan, "#chosen" do
  def item(key, area, batch: "") = described_class::Item.new(key: key, title: key, area: [area], batch: batch)

  def lead = item("a", "lib/x")

  def members = %w[b c d e f].map { |key| item(key, "lib/x/#{key}.rb", batch: "a") }

  def plan = described_class.new([*members, item("z", "lib/z")], [lead], cap: 2, load: 1.0, max_load: 10.0, frozen: [])

  it "counts a group of six as one session against the cap, so another item starts" do
    expect(plan.chosen.map(&:key)).to eq(%w[z])
  end

  it "holds each member of the batch for its lead" do
    expect(plan.skipped.map(&:reason).uniq).to eq(["skipped: held: in the batch of a"])
  end

  it "holds the members for their lead, not for the cap, once the cap is reached" do
    full = described_class.new(members, [lead], cap: 1, load: 1.0, max_load: 10.0, frozen: [])

    expect(full.skipped.map(&:reason).uniq).to eq(["skipped: held: in the batch of a"])
  end
end
