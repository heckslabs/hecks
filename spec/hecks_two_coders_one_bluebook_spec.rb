require "spec_helper"
require "hecks/hecks/adapters/work_areas"
require "hecks/hecks/adapters/dispatching"
require_relative "support/settled_finish"

# Two coders adding different aggregates to one bluebook: both start, the fill does not hold the
# second back for the first, and both land, the second's rebase merged by declaration.
RSpec.describe "Two work items on different sections of one bluebook" do
  include SettledFinish

  def item(key, area) = Hecks::Adapters::Dispatching::Plan::Item.new(key: key, title: key, area: area)

  let(:adds_b) { item("adds-b", ["s.bluebook#B"]) }
  let(:adds_c) { item("adds-c", ["s.bluebook#C"]) }
  let(:repo) { BluebookConflictRepo.new }

  after { repo.remove }

  it "starts the second beside the first" do
    allow(Hecks::Adapters::StartedWork).to receive(:items).and_return([adds_b.to_h])
    expect(Hecks::Adapters::WorkAreas.new.check_area(work: "adds-c", area: adds_c.area).dig(:output, :value))
      .to start_with("adds-c holds s.bluebook#C")
  end

  it "fills the second while the first is started" do
    made = Hecks::Adapters::Dispatching::Plan.new([adds_c], [adds_b], cap: 2, load: 0.5, max_load: 10.0, frozen: [])
    expect(made.chosen.map(&:key)).to eq(["adds-c"])
  end

  it "lands the second after the first, both aggregates kept" do
    repo.diverge("adds-c", adding("B"), adding("C"))
    finish
    expect(repo.read).to include("aggregate \"B\"", "aggregate \"C\"")
  end

  it "refuses the second when both changed the same aggregate, naming it" do
    repo.diverge("adds-c", adding("B"), adding("B").sub(":y", ":z"))
    expect(refusal).to end_with("the merge fixer refused: s.bluebook: aggregate B changed on both sides")
  end
end
