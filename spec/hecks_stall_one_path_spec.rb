require "spec_helper"
require "tmpdir"
require "hecks/hecks/adapters/dispatching"
require_relative "support/stall_one_path_looks"

# Each StallKind row says how its stall is cleared, by its stall item or by a call for help, and
# a stall gets one of them: the watch files only the first kind, and a call is taken only for
# the second.
RSpec.describe "One path per stall" do
  include_context "with a stall watch tap"
  include StallOnePathLooks

  before { write_sources(StallOnePathLooks::SOURCES) }

  it "has every StallKind row say its stall item or a call for help" do
    expect(clearings).to eq(%w[help item])
  end

  it "refuses a row that names any other clearing, by name" do
    row = { kind: "odd", cleared_by: "no" }
    expect { Hecks::Adapters::StallWatching::Clearing.of(row) }.to raise_error(ArgumentError, /odd is cleared by "no"/)
  end

  it "says in the view which path clears each stall" do
    expect(paths).to eq("agent-run-blocked" => "item", "held-lock" => "help")
  end

  it "files the stall its item clears, and none for the stall a call clears" do
    detect("look-1")
    expect(keys("Hecks", "Stall", :stall)).to eq([StallOnePathLooks::BLOCK])
  end

  it "files none for the stall a call clears over three looks" do
    3.times { |beat| look_and_tap("look-#{beat}") }
    expect(row_of("held-lock")).to include(filed: "")
  end
end
