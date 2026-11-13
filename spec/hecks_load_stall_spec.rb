require "spec_helper"
require "tmpdir"
require "hecks/hecks/adapters/dispatching"
require_relative "support/stall_watch_looks"
require_relative "support/process_table_fixtures"

# Tap lines of the machine's load: each crossing is keyed by the beat that heard it, so a rise and
# the fall after it carry different ids.
module LoadStallLooks
  # @param rows [Array<Array(String, String, Integer)>] each event, its beat and its minutes ago
  def write_load_tap(*rows)
    lines = rows.each_with_index.map do |(event, beat, ago), seq|
      line(seq + 1, event, beat, ago).merge(aggregate: "Hecks::Machine")
    end
    File.write(tap, lines.map { |entry| JSON.generate(entry) }.join("\n") << "\n")
  end

  def watching
    aggregate = registry.bluebook("Hecks").aggregate("StallWatch")
    Hecks::Adapters::StallWatching.new(registry: registry, aggregate: aggregate, tap: tap, processes: process_classes)
  end

  def filed = keys("Hecks", "Stall", :stall)
end

# The StallWatch `load` row files a load left over its mark past five minutes as
# `stall-load-<beat>`, naming the busiest process class and the session whose shell owns it; a
# fall on any later beat closes it.
RSpec.describe "the load stall", :aggregate_failures do
  include_context "with a stall watch tap"
  include ProcessTableFixtures
  include LoadStallLooks

  it "files a rise left open five minutes, naming the busiest class and its session" do
    write_load_tap(["LoadRoseAbove", "beat-1", 6])
    detect("look-1")

    expect(filed).to eq(%w[stall-load-beat-1])
    expect(keys("Tickets", "Work", :detail).first).to include("yes x24", "1032.0% CPU", "session s1", "Machine.busiest")
  end

  it "files nothing once a later beat heard the load fall" do
    write_load_tap(["LoadRoseAbove", "beat-1", 9], ["LoadFellBelow", "beat-2", 2])
    detect("look-1")

    expect(filed).to be_empty
  end

  it "files nothing for a rise younger than five minutes" do
    write_load_tap(["LoadRoseAbove", "beat-1", 3])
    detect("look-1")

    expect(filed).to be_empty
  end

  it "files the rise after a fall, keyed by the beat that heard it" do
    write_load_tap(["LoadRoseAbove", "beat-1", 30], ["LoadFellBelow", "beat-2", 20], ["LoadRoseAbove", "beat-3", 8])
    detect("look-1")

    expect(filed).to eq(%w[stall-load-beat-3])
  end
end
