# frozen_string_literal: true

require "spec_helper"
require "support/reaping_fleet"
require "support/reap_turn"

# One reap at a time: a turn a reap holds refuses a second by name, a cleanup a person confirmed
# frees none, and a turn held past its lease (its process died) is taken over.
RSpec.describe "The turn to reap, held by a reap whose process died" do
  include_context "with a reaping fleet"
  include_context "with a first beat at noon"

  before { killed_reap(at: noon) }

  it "refuses a second reap by name" do
    expect(take("r-second", at: noon + 3599)).to include(ReapTurnSteps::REFUSAL)
  end

  it "starts no reap for a session that ends meanwhile", :aggregate_failures do
    expect { done_run }.not_to(change { reaps })
    expect(delivered("ReapWhenASessionEnds")).to eq(0)
  end

  it "gives the turn to a reap that asks after the lease" do
    expect(take("r-late", at: noon + 3600)).to include("ReapTurnTaken")
  end

  it "is not freed by a cleanup a person confirmed" do
    launch("session_cleanup.remove_safe!", "run.value=by-hand", "confirm.value=true", "--wait")
    expect(take("r-second", at: noon + 60)).to include(ReapTurnSteps::REFUSAL)
  end
end
