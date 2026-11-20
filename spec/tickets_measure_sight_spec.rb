require "spec_helper"
require_relative "support/epic_outcome_looks"

# A reading says how far back it could see: to the tap's oldest line, and no further than the
# row's window.
RSpec.describe "how far back a Tickets measure reading saw" do
  include_context "with an epic outcome tap"

  def row(measure) = answered("epic.measures").find { |entry| entry["measure"] == measure }

  it "says a young tap saw back only as far as its oldest line" do
    write_tap(*load_rose(12))

    expect(row("no-ghost-run-is-retired")["saw_back_minutes"]).to eq(12)
  end

  it "says a tap older than the window saw the whole window" do
    write_tap(*load_rose(500))

    expect(row("load-stays-under-its-mark")["saw_back_minutes"]).to eq(60)
  end

  it "says an empty tap saw nothing" do
    hecks
    expect(row("load-stays-under-its-mark")).to include("reading" => 0, "saw_back_minutes" => 0)
  end

  it "says in an epic's evidence how far back its reading saw" do
    missed_epic(5)

    expect(evidence).to include("read 1", "The tap saw back 5 of 60 minutes.")
  end
end
