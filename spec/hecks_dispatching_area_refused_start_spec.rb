require "spec_helper"
require_relative "support/area_refused_launch_fixtures"

# A start whose area claim is refused ends there: the work item is back in the plan, so no coder
# session starts for it and no run is recorded that would keep its key.
RSpec.describe "a start the area claim refuses", :aggregate_failures do
  include AreaRefusedLaunchFixtures

  it "starts no session for the work item and does not yield it a second time" do
    report = confirmed(fill_with(area_refusing), only: { value: "zz-named" })

    expect(report).to include("zz-named cannot claim lib/hecks/agents")
    expect(verbs).not_to include("AgentRun.dispatch!", "Work.yield!")
  end
end
