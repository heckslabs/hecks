require "spec_helper"
require_relative "support/epic_outcome_looks"

# `Epic.measures` reads every `OutcomeMeasure` row from the event tap now, whether or not an epic
# names it, beside the row's bounds.
RSpec.describe Hecks::Adapters::MeasureReadings do
  include_context "with an epic outcome tap"

  def row(measure) = answered("epic.measures").find { |entry| entry["measure"] == measure }

  it "answers every row though no epic names one" do
    hecks
    expect(answered("epic.measures").map { |entry| entry["measure"] }).to include("two-branches-land", "no-stall-is-filed")
  end

  it "reads a row's number beside its bounds", :aggregate_failures do
    write_tap(*load_rose(5, 20), ["Hecks::Machine", "LoadRoseAbove", "old", 90])

    expect(row("load-stays-under-its-mark")).to include("reading" => 2, "at_least" => 0, "at_most" => 0)
    expect(row("load-stays-under-its-mark")["state"]).to eq("missed")
  end

  it "says a row within its bounds is met, with no upper bound where none is declared" do
    write_tap(["Delivery::Landing", "BranchLanded", "a", 5], ["Delivery::Landing", "BranchLanded", "b", 9])

    expect(row("two-branches-land")).to include("reading" => 2, "state" => "met", "at_most" => nil)
  end

  it "answers each row unread where no tap is declared", :aggregate_failures do
    entries = JSON.parse(described_class.new(registry: hecks.registry).measures[:text])

    expect(entries.map { |entry| entry["state"] }.uniq).to eq(%w[unread])
    expect(entries.first["note"]).to eq("no event tap is declared")
  end
end
