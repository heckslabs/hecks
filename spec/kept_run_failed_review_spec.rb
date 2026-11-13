# frozen_string_literal: true

require "spec_helper"
require "support/reaping_fleet"
require "support/kept_run"

# A tidy review the port refuses (the sessions cannot be listed) keeps the run with that refusal
# and a shorter wait, so a failing listing is not asked again at every reap.
RSpec.describe "A run whose tidy review failed" do
  include_context "with a reaping fleet"
  include KeptRun

  before do
    done_run
    File.write(File.join(scratch, "sessions.json"), "not a listing")
    reap
  end

  it "is kept with the refusal and a five-minute wait", :aggregate_failures do
    expect(held["refusal"]).not_to be_empty
    expect(held["review_wait"]).to eq(300)
  end

  it "is not reviewed again inside its wait" do
    expect(tidy(held["kept_at"] + 299)).to include(KeptRun::REFUSAL)
  end
end
