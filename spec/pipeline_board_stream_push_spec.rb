# frozen_string_literal: true

require "spec_helper"
require "timeout"
require_relative "support/pipeline_board_world"
require_relative "support/fake_journal"
require "hecks/pipeline_board/adapters/pipeline_web"

# A reader of the board's stream is woken by a journal line and by nothing else: it is sent every
# tile when it joins, and then the tile a line changed, within a second, with no timer tick (the
# safety net is an hour here).
RSpec.describe Hecks::Adapters::PipelineBoard::Stream do
  let(:journal) { FakeJournal.new }
  let(:html) { ["<p>train</p>"] }
  let(:sent) { Queue.new }
  let(:hub) do
    rows = [{ tile: "train", reads: "Hecks::SendTrain" }]
    tiles = Hecks::Adapters::PipelineBoard::Tiles.new(rows: rows, renderers: { "train" => -> { html[0] } })
    watch = Hecks::Adapters::PipelineBoard::Watch.new(path: "unused", source: -> { journal })
    Hecks::Adapters::PipelineBoard::Hub.new(tiles: tiles, watch: watch, net_seconds: 3600).start
  end

  before do
    stream = described_class.new(hub: hub)
    @reader = Thread.new { stream.each { |event| sent << event } }
  end

  after do
    @reader.kill
    hub.stop
  end

  def next_tile
    Timeout.timeout(1) do
      loop do
        event = sent.pop
        return event[:tile] if event.key?(:tile)
      end
    end
  end

  it "sends every tile on joining" do
    expect(next_tile[:html]).to eq("<p>train</p>")
  end

  it "sends the tile a journal line changed within a second, with the line's seq", :aggregate_failures do
    next_tile
    html[0] = "<p>moved</p>"
    journal.push("aggregate" => "Hecks::SendTrain", "seq" => 3)
    expect(next_tile).to include(id: "train", seq: 3, html: "<p>moved</p>")
  end

  it "sends nothing for a journal line that changes no tile" do
    next_tile
    journal.push("aggregate" => "Hecks::GateRun", "seq" => 4)
    expect { next_tile }.to raise_error(Timeout::Error)
  end
end
