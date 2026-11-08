require "spec_helper"
require_relative "support/roll_forward_fixtures"

# Planning a Work item starts a rolling fill: RollWhenWorkIsPlanned hands Roll.Start the one
# argument it takes, so no reaction is refused and a roll is requested.
RSpec.describe "RollWhenWorkIsPlanned" do
  include RollForwardFixtures

  let(:hecks) { boot_hecks_in_memory }

  before do
    Hecks::Adapters::Dispatching::LastRoll.reset!
    Hecks::Runtime::AdapterLookup.standing_in(->(_port, _asked) { rolling({}) }) do
      hecks.dispatch_flat("Tickets::Work.Plan", work: { value: "probe-item" }, title: { value: "Probe" },
                                                detail: { value: "d" }, area: [])
    end
  end

  def reaction(policy) = hecks.reactions.find { |row| row[:policy] == policy }

  it "delivers the policy's trigger" do
    expect(reaction("RollWhenWorkIsPlanned")).to include(trigger: "Hecks::Roll.Start", delivered: true)
  end

  it "refuses no reaction" do
    expect(hecks.reactions.filter_map { |row| row[:reason] }).to be_empty
  end

  it "starts a roll that is answered" do
    expect(hecks.registry.event_log.map(&:name)).to include("RollRequested", "RollAnswered")
  end
end
