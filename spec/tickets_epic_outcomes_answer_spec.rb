require "spec_helper"
require_relative "support/epic_outcome_looks"

# `Epic.outcomes` answers the epics in ranked order, each with its members counted and the state a
# reopening left.
RSpec.describe "the Tickets Epic's outcomes answered together" do
  include_context "with an epic outcome tap"

  def outcome(key = "e1") = answered("epic.outcomes").find { |entry| entry["epic"] == key }

  it "keeps a missed measure missed when the miss reopens a complete epic" do
    epic
    close_members("m1")
    write_tap(*load_rose(5))
    cli("epic.review!", "to=e1")

    expect(outcome).to include("measured" => "missed", "status" => "open")
  end

  it "counts the members by what became of them" do
    epic
    %w[m1 m2 m3].each { |key| member(key) }
    finish("m1")
    cli("work.drop!", "to=m2", "reason.value=not wanted")

    expect(outcome["members"]).to eq("done" => 1, "dropped" => 1, "open" => 1, "all" => 3)
  end

  it "answers the epics lowest tier first, an unranked one last" do
    epic
    cli("epic.open!", "epic.value=e2", "title.value=Epic e2", "outcome.value=It is carried out")
    cli("epic.rank!", "to=e2", "tier.value=2")

    expect(answered("epic.outcomes").map { |entry| entry["epic"] }).to eq(%w[e2 e1])
  end
end
