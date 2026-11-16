require "spec_helper"
require "tmpdir"
require "hecks/hecks/adapters/dispatching"
require_relative "support/stall_watch_looks"
require_relative "support/process_table_fixtures"
require_relative "support/load_stall_looks"

# Only the beat's readings (`launchd-<epoch>`) are the fleet's load: a landing gate reads the
# machine once per step under `<sha>-<step>`, a key no fall follows.
RSpec.describe "the load stall and a gate step's reading", :aggregate_failures do
  include_context "with a stall watch tap"
  include ProcessTableFixtures
  include LoadStallLooks

  it "files nothing for a gate step's rise that no fall followed under its key" do
    write_load_tap(["LoadRoseAbove", "fa15ef8d-2", 10], ["LoadFellBelow", "launchd-9", 1])
    detect("look-1")

    expect(filed).to be_empty
  end

  it "files nothing for a gate step's rise while the beat has read no rise" do
    write_load_tap(["LoadRoseAbove", "fa15ef8d-2", 10])
    detect("look-1")

    expect(filed).to be_empty
  end

  it "still files a beat's rise that comes after a gate step's" do
    write_load_tap(["LoadRoseAbove", "fa15ef8d-2", 12], ["LoadRoseAbove", "launchd-5", 8])
    detect("look-1")

    expect(filed).to eq(%w[stall-load-launchd-5])
  end

  it "lets a fall under any key close a beat's rise" do
    write_load_tap(["LoadRoseAbove", "launchd-5", 12], ["LoadFellBelow", "fa15ef8d-2", 3])
    detect("look-1")

    expect(filed).to be_empty
  end
end
