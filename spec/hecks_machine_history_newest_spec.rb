require "spec_helper"
require "tmpdir"
require_relative "support/machine_history_rows"

# The reading whose memory and lane states the next one stands on is the one taken latest by its
# stamp. A store lists records by key, so a key that sorts after the beat's keys must not stand as
# the last reading for good. The load is not read here: it stands in the one LoadStanding record.
RSpec.describe Hecks::Adapters::MachineSampling::History do
  include MachineHistoryRows

  def memory_after(readings) = Dir.mktmpdir { |dir| sqlite_history_of(readings, dir).states[:memory] }

  def stamped(at, memory) = { load_state: "below", memory_state: memory, taken_at: "2026-11-20T#{at}Z" }

  it "is not shadowed by an unstamped reading whose key sorts last" do
    readings = [["launchd-1", stamped("10:00:00", "ok")], ["launchd-2", stamped("10:05:00", "low")],
                ["stall", { load_state: "below", memory_state: "ok" }]]

    expect(memory_after(readings)).to eq("low")
  end

  it "takes the latest stamp, not the latest key" do
    readings = [["launchd-2", stamped("10:05:00", "low")], ["zz-gate-1", stamped("09:00:00", "ok")]]

    expect(memory_after(readings)).to eq("low")
  end

  it "stands on the last listed reading while none is stamped, as the first stamped reading does" do
    readings = [["launchd-1", { load_state: "below", memory_state: "low" }], ["stall", { load_state: "below" }]]

    expect(memory_after(readings)).to eq("ok")
  end
end
