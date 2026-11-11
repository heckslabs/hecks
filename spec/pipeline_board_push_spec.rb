# frozen_string_literal: true

require "spec_helper"
require "json"
require "timeout"
require_relative "support/pipeline_board_world"
require_relative "support/fake_journal"
require "hecks/pipeline_board/adapters/pipeline_web"

# The board learns of a change from the journal and pushes only the tiles it changed: a line of an
# aggregate a tile reads draws that tile again, a drawing that came out the same pushes nothing, a
# line no tile reads draws nothing, and a reader is woken by the line, not by a clock.
RSpec.describe Hecks::Adapters::PipelineBoard::Hub do
  let(:journal) { FakeJournal.new }
  let(:rows) do
    [{ tile: "fill", reads: "Tickets::Work, Hecks::AgentRun" }, { tile: "train", reads: "Hecks::SendTrain" }]
  end
  let(:drawn) { Hash.new(0) }
  let(:html) { { "fill" => "<p>fill</p>", "train" => "<p>train</p>" } }
  let(:hub) do
    renderers = %w[fill train].to_h { |id| [id, -> { (drawn[id] += 1) && html.fetch(id) }] }
    tiles = Hecks::Adapters::PipelineBoard::Tiles.new(rows: rows, renderers: renderers)
    watch = Hecks::Adapters::PipelineBoard::Watch.new(path: "unused", source: -> { journal })
    described_class.new(tiles: tiles, watch: watch, net_seconds: 3600).start
  end

  after { hub.stop }

  # The wake the journal line `data` causes.
  def wake_after(data)
    queue = hub.join
    journal.push(data)
    Timeout.timeout(1) { queue.pop }
  end

  def line(aggregate, event = "Anything", seq = 7) = { "aggregate" => aggregate, "event" => event, "seq" => seq }

  it "draws only the tiles that read the line's aggregate, and pushes them with the line's seq", :aggregate_failures do
    wake = wake_after(line("Hecks::SendTrain"))

    expect(wake.fragments.map(&:to_h)).to eq([{ id: "train", seq: 7, html: "<p>train</p>" }])
    expect(drawn).to eq("train" => 1)
  end

  it "pushes nothing when a tile is drawn again and comes out the same" do
    wake_after(line("Hecks::SendTrain"))

    expect(wake_after(line("Hecks::SendTrain", "Another", 8)).fragments).to be_empty
  end

  it "pushes a tile again when its drawing changes, whatever the event is called" do
    wake_after(line("Hecks::SendTrain", "Boarded"))
    html["train"] = "<p>pushed</p>"

    expect(wake_after(line("Hecks::SendTrain", "NobodyDeclaredThis", 9)).fragments.map(&:html)).to eq(["<p>pushed</p>"])
  end

  it "draws nothing for a line no tile reads, or a line with no aggregate", :aggregate_failures do
    wake_after(line("Hecks::GateRun"))
    wake_after(line(nil, "Reaction", 8))

    expect(drawn).to be_empty
  end

  it "wakes a reader for a line no tile reads, so the feed can be read again" do
    expect(wake_after(line("Hecks::GateRun")).fragments).to be_empty
  end

  it "shows an unknown note for the tile whose drawing fails and leaves the other as it was", :aggregate_failures do
    html.delete("train")
    wake = wake_after(line("Hecks::SendTrain"))

    expect(wake.fragments.map(&:id)).to eq(["train"])
    expect(wake.fragments.first.html).to include("unknown: KeyError")
  end

  it "reads the Tile rows of the bluebook, which name aggregates and no event", :aggregate_failures do
    declared = Hecks::Adapters::PipelineBoard::Rules.rows("Tile")

    expect(declared.map { |row| row[:tile] }).to eq(%w[fill train])
    expect(declared.flat_map { |row| row[:reads].split(",").map(&:strip) }).to all(match(/\A\w+::\w+\z/))
  end

  it "answers every tile as it stands to a reader that joins" do
    expect(hub.current.map(&:id)).to eq(%w[fill train])
  end
end
