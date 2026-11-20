require "spec_helper"
require_relative "support/epic_outcome_looks"

# Naming another row clears the last reading: it was the earlier row's, and the new one is unread.
RSpec.describe "the Tickets Epic's outcome when another measure is named" do
  include_context "with an epic outcome tap"

  def outcome = answered("epic.outcomes").find { |entry| entry["epic"] == "e1" }

  it "returns a met measure to unread, without its evidence" do
    epic
    close_members("m1")
    cli("epic.measure_by!", "to=e1", "measure.value=two-branches-land")

    expect(outcome).to include("measure" => "two-branches-land", "measured" => "unread", "evidence" => "")
  end
end
