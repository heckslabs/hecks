require "spec_helper"
require_relative "support/stand_in_claude"
require_relative "support/wakes_coder_helpers"
require_relative "support/change_review_helpers"

# The architect's review of a decision the Tickets store recorded: asked on the event, so retiring
# the decision files removes only the path clause; an unsound decision names no coder, and its
# findings stay on its row for the orchestrator to read.
RSpec.describe "the architect's review of a recorded decision" do
  include_context "with a stand-in claude"
  include WakesCoderHelpers
  include ChangeReviewHelpers

  before(:all) { @hecks = boot_hecks_in_memory }

  before { fake_runner([]) }

  def draft(adr) = launch("tickets", "Adr.draft!", "adr.value=#{adr}", "title.value=A decision", "--wait")

  it "asks the architect about a decision the Tickets store recorded" do
    draft("0300")
    expect(change_review("0300")["status"]).to eq("asked")
  end

  it "keeps an unsound decision's findings on its row, judging no verdict", :aggregate_failures do
    draft("0301")
    architect_closes("0301", "Verdict: rethink. Split the aggregate.")
    expect(change_review("0301").values_at("status", "findings")).to eq(["sent_back", "Verdict: rethink. Split the aggregate."])
    expect(verdict_for("0301")).to be_nil
  end
end
