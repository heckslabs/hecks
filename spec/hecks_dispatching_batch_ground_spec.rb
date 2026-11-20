require "spec_helper"
require "hecks/hecks/adapters/dispatching"

# The lead of a batch holds its own ground and the area of each member still to be built; a member
# committed on its branch lets its area go, so it does not hold back an item of another group.
RSpec.describe Hecks::Adapters::Dispatching::BatchGround do
  let(:plan_class) { Hecks::Adapters::Dispatching::Plan }
  let(:changed) { { "a" => %w[lib/x/a.rb lib/x/b/b.rb] } }

  def item(key, area, batch: "", commit: "")
    plan_class::Item.new(key: key, title: key, area: area, batch: batch, batch_commit: commit)
  end

  def lead = plan_class::Item.new(key: "a", title: "a", area: %w[lib/x/a.rb lib/x/b lib/x/c], batched: members)

  def members = [item("b", %w[lib/x/b], batch: "a", commit: "abc123"), item("c", %w[lib/x/c], batch: "a")]

  def branch = ->(work) { Hecks::Adapters::Dispatching::EffectiveArea.choose(work.area, changed.fetch(work.key, [])) }

  def ground = described_class.new(branch, root: "/repo")

  def plan(other) = plan_class.new([other], [lead], cap: 6, load: 1.0, max_load: 10.0, frozen: [], effective: ground)

  it "lets a committed member's area go and keeps the area of one still to be built" do
    expect(ground.call(lead)).to eq(%w[lib/x/a.rb lib/x/c])
  end

  it "does not hold back an item of another group on a committed member's area" do
    expect(plan(item("z", %w[lib/x/b/z.rb])).chosen.map(&:key)).to eq(%w[z])
  end

  it "still holds back an item on the area of a member not yet committed" do
    expect(plan(item("z", %w[lib/x/c/z.rb])).skipped.first.reason).to include("overlaps a")
  end

  it "reads a work item that leads no batch by its branch alone" do
    expect(described_class.new(branch).call(item("a", lead.area))).to eq(%w[lib/x/a.rb lib/x/b/b.rb])
  end
end
