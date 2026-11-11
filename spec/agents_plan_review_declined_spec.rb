require "spec_helper"
require_relative "support/stand_in_claude"
require_relative "support/wakes_coder_helpers"

# A review whose architect run is declined (the repo is gone) is unstarted with the reason, and the
# coder waiting on its Work item is woken with that reason instead of waiting for a verdict.
RSpec.describe "a declined plan review waking the coder waiting for it" do
  include_context "with a stand-in claude"
  include WakesCoderHelpers

  before(:all) { @hecks = boot_hecks_in_memory }

  let(:woken) { [] }

  before { fake_runner(woken) }

  it "marks the review unstarted with the reason", :aggregate_failures do
    wait_as_coder("d-one")
    request_in_missing_repo("d-one")
    row = review_of("d-one")
    expect(row["verdict"]).to be_nil
    expect(row["reason"].to_s).not_to be_empty
  end

  it "answers the coder run with the reason", :aggregate_failures do
    wait_as_coder("d-two")
    request_in_missing_repo("d-two")
    expect(runs_woken).to eq(["d-two"])
    expect(woken.first[:answer].to_s).not_to be_empty
  end

  it "does nothing for a declined run that is no review" do
    launch("agent_run.dispatch!", "run.value=plain", "repo.value=#{scratch}/gone", "brief.value=x", "--wait")
    expect(woken).to be_empty
  end
end
