require "spec_helper"
require "tmpdir"
require "hecks/hecks/adapters/dispatching"
require_relative "support/stall_watch_looks"
require_relative "support/process_table_fixtures"
require_relative "support/load_stall_looks"

# The StallWatch `load` row files a load left over its mark past five minutes as
# `stall-load-<beat>`, naming the busiest process class and the session whose shell owns it; a
# fall on any later beat closes it.
RSpec.describe "the load stall", :aggregate_failures do
  include_context "with a stall watch tap"
  include ProcessTableFixtures
  include LoadStallLooks

  it "files a rise left open five minutes, naming the busiest class and its session" do
    write_load_tap(["LoadRoseAbove", "launchd-1", 6])
    detect("look-1")
    expect(filed).to eq(%w[stall-load-launchd-1])
    expect(keys("Hecks", "Stall", :detail).first).to include("yes x24", "1032.0% CPU", "session s1", "Machine.busiest")
  end

  it "plans no work item for a filed load stall and wakes the orchestrator once" do
    write_load_tap(["LoadRoseAbove", "launchd-1", 6])
    detect("look-1")
    expect([keys("Tickets", "Work", :work), events_named("CoordinatorWoken")]).to eq([[], 1])
  end

  it "files nothing once a later beat heard the load fall" do
    write_load_tap(["LoadRoseAbove", "launchd-1", 9], ["LoadFellBelow", "launchd-2", 2])
    detect("look-1")
    expect(filed).to be_empty
  end

  it "files nothing for a rise younger than five minutes" do
    write_load_tap(["LoadRoseAbove", "launchd-1", 3])
    detect("look-1")
    expect(filed).to be_empty
  end

  it "files the rise after a fall, keyed by the beat that heard it" do
    write_load_tap(["LoadRoseAbove", "launchd-1", 30], ["LoadFellBelow", "launchd-2", 20], ["LoadRoseAbove", "launchd-3", 8])
    detect("look-1")
    expect(filed).to eq(%w[stall-load-launchd-3])
  end
end
