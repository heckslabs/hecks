require "spec_helper"
require "tmpdir"
require "hecks/hecks/adapters/dispatching"
require_relative "support/stall_watch_looks"

# Tap lines of the pressure beats, and the keys a look filed, for the beat-uncleared group.
module BeatUnclearedLooks
  def write_beats(rows)
    lines = rows.each_with_index.map do |(event, id, ago), seq|
      line(seq + 1, event, id, ago).merge(aggregate: "Signalbox::Beat")
    end
    File.write(tap, lines.map { |entry| JSON.generate(entry) }.join("\n") << "\n")
  end

  def keys
    aggregate = registry.bluebook("Hecks").aggregate("Stall")
    registry.repository("Hecks", aggregate).all.map { |record| Hecks::Adapters::StartedWork.value(record, :stall).to_s }
  end
end

# A pressure beat that looked and was never cleared (its copy was refused) is a stall; a later
# beat that publishes or faults, whatever its own key, closes it.
RSpec.describe "StallWatch beat-uncleared" do
  include_context "with a stall watch tap"
  include BeatUnclearedLooks

  STAYED = [["BeatRecorded", "launchd-1", 9]].freeze
  UNCLEARED_CASES = {
    "a beat that stayed looked"        => [STAYED, ["stall-beat-uncleared-launchd-1"]],
    "a beat that looked 2 minutes ago" => [[["BeatRecorded", "launchd-1", 2]], []],
    "a beat that was published"        => [STAYED + [["BeatPublished", "launchd-1", 8]], []],
    "a later beat's publication"       => [STAYED + [["BeatPublished", "launchd-2", 3]], []],
    "a gate step's looked beat"        => [[["BeatRecorded", "abc123-quick", 9]], []]
  }.freeze

  UNCLEARED_CASES.each do |name, (rows, filed)|
    it "files #{filed.empty? ? "nothing" : "one stall"} for #{name}" do
      write_beats(rows)
      detect("look-1")

      expect(keys).to eq(filed)
    end
  end

  it "lists one impediment, keyed by the kind, for many beats that stayed looked" do
    write_beats([["BeatRecorded", "launchd-1", 12], ["BeatRecorded", "launchd-2", 10], ["BeatRecorded", "launchd-3", 8]])
    detect("look-1")
    rows = watching.impediments(run: "look-1")

    expect(rows.map { |row| row[:impediment] }).to eq(["stall-beat-uncleared"])
  end
end
