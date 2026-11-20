require "spec_helper"
require "tmpdir"
require "hecks/hecks/adapters/dispatching"
require_relative "support/shared_file_looks"

# A pair of branches that share files is one entry of the impediment view until either tip moves:
# never filed as a stall, sorted by age among the tap's impediments, and read only as its row says.
RSpec.describe "StallWatch impediments: one entry per pair of branches" do
  include_context "with open branches that share a file"

  it "is a new entry once either branch's tip moves" do
    write_sources(started)
    before = pair[:stall]
    tips["two"] = "ddd4444"

    expect(pair[:stall]).not_to eq(before)
  end

  it "is never offered for filing" do
    write_sources(started)
    expect(unclosed_kinds).to be_empty
  end

  it "sorts among the tap's impediments, the oldest first" do
    write_sources(started + [["BoardingHoldSettled", "hold-1", 15, "Hecks::BoardingHold"]])
    expect(kinds).to eq(%w[held-lock branches-share-files])
  end

  it "refuses a row that names a read it does not know" do
    shared = Hecks::Adapters::StallWatching::SharedFiles.new([{ read: "other" }], 0, branches: branch_read)
    expect { shared.rows([], "look-1") }.to raise_error(ArgumentError, /unknown read "other"/)
  end

  it "is cleared by a call for help, under a key a call may hold", :aggregate_failures do
    write_sources(started)

    expect(pair).to include(cleared_by: "help", impediment: "stall-branches-share-files-one.two-aaa1111-bbb2222")
    expect("help-#{pair[:impediment]}").to match(/\Ahelp-stall-[A-Za-z0-9._-]+\z/)
  end

  it "refuses a row that names a clearing it does not know, by name" do
    rows = [{ kind: "odd", read: "shared-files", aggregate: "Tickets::Work", opens: "WorkStarted", cleared_by: "no" }]
    write_sources(started)
    shared = Hecks::Adapters::StallWatching::SharedFiles.new(rows, Time.now.to_i, branches: branch_read)
    expect { shared.rows(tap_lines, "look-1") }.to raise_error(ArgumentError, /odd is cleared by "no"/)
  end
end
