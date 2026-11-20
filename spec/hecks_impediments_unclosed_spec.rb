require "spec_helper"
require "tmpdir"
require "hecks/hecks/adapters/dispatching"
require_relative "support/impediment_looks"

# What the impediment view keeps that a look's Unclosed does not: a filed stall, and the
# rows a call for help clears, which no look files.
RSpec.describe "StallWatch impediments beside Unclosed" do
  include_context "with a stall watch tap"
  include ImpedimentLooks

  it "leaves out a source younger than its row's minutes" do
    write_sources([["BoardingHoldSettled", "hold-1", 4, "Hecks::BoardingHold"]])
    expect(kinds).to be_empty
  end

  it "leaves out a hold older than its window, which expired by itself" do
    write_sources([["BoardingHoldSettled", "hold-1", 25, "Hecks::BoardingHold"]])
    expect(kinds).to be_empty
  end

  it "keeps a filed stall that Unclosed no longer offers, naming its stall", :aggregate_failures do
    write_sources(ImpedimentLooks::STANDING + [["StallFiled", "stall-agent-run-blocked-stuck", 1, "Hecks::Stall"]])

    expect(row_of("agent-run-blocked")).to include(filed: "stall-agent-run-blocked-stuck")
    expect(unclosed_kinds).not_to include("agent-run-blocked")
  end

  it "offers Unclosed only the rows their stall item clears, so a source a call clears files no stall" do
    write_sources(ImpedimentLooks::STANDING)
    expect(unclosed_kinds).to eq(%w[agent-run-blocked])
  end

  it "files nothing for a source a call for help clears when the watch looks" do
    write_sources(ImpedimentLooks::STANDING.first(4))
    detect("look-1")
    expect(keys("Hecks", "Stall", :stall)).to be_empty
  end
end
