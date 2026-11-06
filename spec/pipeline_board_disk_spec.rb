# frozen_string_literal: true

require "spec_helper"
require_relative "support/pipeline_board_world"

# The Disk free metric: the reader's reading of `df`, the tile's state at each floor, and the tile
# among the board's metrics. The reader is handed canned `df -Pk` output, so no real volume is read.
RSpec.describe "the Disk free metric" do
  include PipelineBoardWorld

  # `df -Pk` for a volume of 100 gigabytes with 20 gigabytes left.
  let(:df_output) do
    "Filesystem 1024-blocks Used Available Capacity Mounted on\n/dev/disk3s5 104857600 83886080 20971520 80% /\n"
  end
  let(:floors) { { attention_gb: 20, failed_gb: 5 } }
  let(:tiles) { Object.new.extend(Hecks::Adapters::PipelineBoard::DiskTiles) }

  def reader(output) = Hecks::Adapters::PipelineDisk.new(root: "/x", settings: { df: ->(_) { output } })

  def tile_at(free_gb)
    reading = { free_gb: free_gb, total_gb: 100.0, used_percent: 80 }
    tiles.disk(reading, floors)
  end

  it "reads the free and total gigabytes and the percent used from df" do
    expect(reader(df_output).free).to eq(free_gb: 20.0, total_gb: 100.0, used_percent: 80)
  end

  it "says why when df printed no volume line" do
    expect { reader("Filesystem\n").free }.to raise_error(Hecks::Adapters::PipelineBoard::Unavailable, /no volume line/)
  end

  it "is ok above the attention floor", :aggregate_failures do
    expect(tile_at(21.0)).to include(state: "ok", value: 21.0, unit: "GB")
    expect(tile_at(21.0)[:detail]).to eq("80% of 100.0 GB used")
  end

  it "asks for attention at the attention floor" do
    expect(tile_at(20.0)).to include(state: "attention")
  end

  it "fails at the failure floor" do
    expect(tile_at(5.0)).to include(state: "failed")
  end

  it "is unknown, with the reason, when the disk could not be read" do
    unreadable = tiles.disk({ unknown: "df printed nothing" }, floors)
    expect(unreadable).to include(state: "unknown", detail: "unknown: df printed nothing")
  end

  it "is one of the board's metrics, judged against the floors in the data", :aggregate_failures do
    data = { disk: { free_gb: 4.0, total_gb: 100.0, used_percent: 96 }, disk_health: floors }
    found = Hecks::Adapters::PipelineBoard::Metrics.tiles(data, Time.now).find { |metric| metric[:id] == "disk" }
    expect(found).to include(label: "Disk free", state: "failed", value: 4.0)
  end

  it "reads the floors from the Hecks world", :aggregate_failures do
    registry = Hecks.describe(File.join(InMemoryDomain::ROOT, "lib/hecks/hecks")).registry
    expect(Hecks::Adapters::PipelineBoard::DiskTiles.health(registry)).to eq(attention_gb: 20, failed_gb: 5)
    expect(Hecks::Adapters::PipelineBoard::DiskTiles.health(nil)).to eq(attention_gb: 20, failed_gb: 5)
  end
end
