# frozen_string_literal: true

require "spec_helper"
require "support/reaping_fleet"

# `SessionCleanup.Reap` over a finished run whose session `claude agents` does not list: the run
# is recorded tidied, so the next beat's reap does not review it again.
RSpec.describe "SessionCleanup.Reap of a run whose session is gone" do
  include_context "with a reaping fleet"

  it "records the run tidied without a claude rm", :aggregate_failures do
    gone_run
    expect(reap).to start_with("removed 1 sessions and 0 worktrees; kept 0")
    expect(removed).to be_empty
  end

  it "leaves the run out of the next reap" do
    gone_run
    reap
    expect(launch("agent_run.tidyable")).not_to include("r-done")
  end
end
