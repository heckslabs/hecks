require "spec_helper"
require_relative "support/epic_outcome_looks"

# An epic keeps what its last reading found, and `Epic.outcomes` answers it: met, missed, unread,
# or unstated for an epic that names no measure.
RSpec.describe "the Tickets Epic's kept outcome" do
  include_context "with an epic outcome tap"

  def outcome(key = "e1") = answered("epic.outcomes").find { |entry| entry["epic"] == key }

  it "answers an epic that names no measure as unstated" do
    epic(nil)
    expect(outcome).to include("measure" => nil, "measured" => "unstated")
  end

  it "answers an epic whose measure was never read as unread" do
    epic
    expect(outcome).to include("measure" => "load-stays-under-its-mark", "measured" => "unread")
  end

  it "keeps that the measure was met when the epic completes", :aggregate_failures do
    epic
    close_members("m1")

    expect(measured).to eq("met")
    expect(outcome).to include("measured" => "met", "status" => "complete")
  end

  it "keeps that the measure was missed", :aggregate_failures do
    missed_epic(5)

    expect(measured).to eq("missed")
    expect(outcome["evidence"]).to include("read 1")
  end
end
