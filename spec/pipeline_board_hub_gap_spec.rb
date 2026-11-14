# frozen_string_literal: true

require "spec_helper"
require "timeout"
require_relative "support/fake_journal"
require "hecks/pipeline_board/adapters/pipeline_web"

# A run of journal lines costs one drawing of a tile, not one per line: every line wakes the
# readers at once, and the tiles it marked are drawn once the drawer's rest is over.
RSpec.describe Hecks::Adapters::PipelineBoard::Hub do
  let(:journal) { FakeJournal.new }
  let(:drawn) { [] }
  let(:hub) do
    rows = [{ tile: "train", reads: "Hecks::SendTrain" }]
    tiles = Hecks::Adapters::PipelineBoard::Tiles.new(rows: rows, renderers: { "train" => -> { "<p>#{drawn.push(1).size}</p>" } })
    watch = Hecks::Adapters::PipelineBoard::Watch.new(path: "unused", source: -> { journal })
    described_class.new(tiles: tiles, watch: watch, net_seconds: 3600, gap: -> { 3600 }).start
  end

  after { hub.stop }

  def line(seq) = journal.push("aggregate" => "Hecks::SendTrain", "seq" => seq)

  # The next `count` wakes a reader is sent.
  def wakes(reader, count)
    Timeout.timeout(5) { Array.new(count) { reader.pop } }
  end

  it "wakes the readers once for every line of a run" do
    reader = hub.join
    3.times { |seq| line(seq + 1) }
    expect(wakes(reader, 3).map(&:seq)).to eq([1, 2, 3])
  end

  it "draws a tile once for a run of lines, while the hub rests" do
    reader = hub.join
    4.times { |seq| line(seq + 1) }
    wakes(reader, 4)
    expect(drawn.size).to eq(1)
  end

  it "pushes the drawing with the first line of a run, and none with the next" do
    reader = hub.join
    2.times { |seq| line(seq + 1) }
    expect(wakes(reader, 2).map { |wake| wake.fragments.map(&:id) }).to eq([["train"], []])
  end

  it "declares the rest between drawings as a setting of the bluebook" do
    expect(Hecks::Adapters::PipelineBoard::Rules.setting("tile_redraw_seconds")).to eq(2)
  end
end
