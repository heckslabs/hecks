require "spec_helper"
require "tmpdir"
require "hecks/hecks/adapters/dispatching"
require_relative "support/stall_watch_looks"

# Judges of a volume and tap lines of the `data` volume, for a group with a stall watch tap.
module DiskSpaceStallLooks
  # @param run [String] the judge's key
  # @param state [String] the level judged
  # @param previous [String, nil] the level the volume was at
  # @param volume [String, nil] the volume judged
  def judge(run, state, previous = nil, volume: "data")
    args = { run: { value: run }, free_gb: 10, used_percent: 95, state: { value: state } }
    args[:volume] = { value: volume } if volume
    args[:previous] = { value: previous } if previous
    dispatch("Hecks::Level.Judge", **args)
  end

  # @param rows [Array<Array(String, Integer)>] each event of the `data` volume and its minutes ago
  def write_volume_tap(*rows)
    lines = rows.each_with_index.map { |(event, ago), seq| line(seq + 1, event, "data", ago).merge(aggregate: "Hecks::Volume") }
    File.write(tap, lines.map { |entry| JSON.generate(entry) }.join("\n") << "\n")
  end
end

# A volume that is judged high rises, and eases when a later judge finds it below high; the
# StallWatch `disk` row files a volume left high past its minutes as `stall-disk-<volume>`.
RSpec.describe "the DiskSpace stall", :aggregate_failures do
  include_context "with a stall watch tap"
  include DiskSpaceStallLooks

  it "raises a volume judged high, and eases it when it comes back below high" do
    judge("j1", "high", "rising")
    judge("j2", "calm", "high")

    expect([events_named("VolumeRose"), events_named("VolumeEased")]).to eq([1, 1])
  end

  it "moves nothing for a level that stays where it was, or a judge that names no volume" do
    judge("j1", "calm", "calm")
    judge("j2", "high", "high")
    judge("j3", "high", "rising", volume: nil)

    expect([events_named("VolumeRose"), events_named("VolumeEased")]).to eq([0, 0])
  end

  it "files a volume high past half an hour once, for the pruner" do
    write_volume_tap(["VolumeRose", 40])
    detect("look-1")

    expect(keys("Hecks", "Stall", :stall)).to eq(%w[stall-disk-data])
    expect(keys("Tickets", "Work", :detail).first).to include("Relief.relieve!", "never remove them")
  end

  it "files nothing for a volume that eased" do
    write_volume_tap(["VolumeRose", 40], ["VolumeEased", 20])
    detect("look-1")

    expect(keys("Hecks", "Stall", :stall)).to be_empty
  end
end
