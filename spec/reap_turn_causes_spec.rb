# frozen_string_literal: true

require "spec_helper"
require "support/reaping_fleet"
require "support/reap_turn"

# A session that ends reaps at once, whatever the beat's spacing; a beat inside the half hour
# sends no `AgentRun.Tidy`; and a reap the port refuses frees the turn like one it reports.
RSpec.describe "The turn to reap, asked by a session's end" do
  include_context "with a reaping fleet"
  include_context "with a first beat at noon"

  it "reaps at once, inside the beat's half hour, and frees the turn", :aggregate_failures do
    done_run
    expect(delivered("ReapWhenASessionEnds")).to eq(1)
    expect(delivered("FreeTheTurnWhenTheReapIsReported")).to eq(2)
  end

  it "sends no tidy for a finished run on a later beat inside the half hour", :aggregate_failures do
    done_run(user("one more thing"))
    expect { beat("b2") }.not_to(change { delivered("TidyEveryFinishedRun") })
    expect(delivered("TidyEveryFinishedRun")).to eq(1)
  end

  it "frees the turn when the port refuses the reap", :aggregate_failures do
    File.write(File.join(scratch, "sessions.json"), "not a listing")
    take("r-refused", at: noon)
    expect(delivered("FreeTheTurnWhenTheReapIsRefused")).to eq(1)
    expect(take("r-next", at: noon)).to include("ReapTurnTaken")
  end
end
