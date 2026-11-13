# frozen_string_literal: true

require "spec_helper"
require "support/reaping_fleet"
require "support/kept_run"

# A finished run the tidy review keeps stays finished, so every reap sends `AgentRun.Tidy` for it.
# `Retain` records when it was kept and its wait, and `Tidy` refuses it until the wait has passed.
RSpec.describe "A run the tidy review keeps" do
  include_context "with a reaping fleet"
  include KeptRun

  before do
    done_run(user("one more thing"))
    reap
  end

  it "records why it was kept, when, and its wait", :aggregate_failures do
    expect(held["refusal"]).to start_with("a person replied")
    expect(held["kept_at"]).to be_positive
    expect(held["review_wait"]).to eq(3600)
  end

  it "is not reviewed again inside its wait" do
    expect(tidy(held["kept_at"] + 3599)).to include(KeptRun::REFUSAL)
  end

  it "is not reviewed again by the next reap", :aggregate_failures do
    expect(reap).to include("kept")
    expect(tidy).to include(KeptRun::REFUSAL)
  end

  it "is reviewed again once its wait has passed" do
    expect(tidy(held["kept_at"] + 3600)).to include("SessionReviewed")
  end

  it "is reviewed at the next reap once it is released" do
    launch("agent_run.release!", "to=r-done", "--wait")
    expect(tidy).to include("SessionReviewed")
  end
end
