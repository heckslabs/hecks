# frozen_string_literal: true

require "spec_helper"
require "hecks/pipeline_board/adapters/pipeline_web"

# A tile that never finishes drawing must never hold a page: a request reads the last drawing and
# the drawing itself is bounded.
RSpec.describe Hecks::Adapters::PipelineBoard::Tiles do
  let(:rows) { [{ tile: "fill", reads: "Fill" }, { tile: "train", reads: "Train" }] }
  let(:drawing) { Queue.new }
  let(:renderers) { { "fill" => -> { drawing.push(:begun) && Queue.new.pop }, "train" => -> { "<p>train</p>" } } }
  let(:tiles) { described_class.new(rows: rows, renderers: renderers) }

  before { stub_const("#{described_class}::DRAW_SECONDS", 0.1) }

  it "reads a tile that was never drawn as a note, without drawing it" do
    expect(tiles.html("train")).to eq(described_class::NOT_DRAWN)
  end

  it "answers the page while a drawing is stuck holding the lock" do
    drawer = Thread.new { tiles.refresh(1) }
    drawing.pop
    expect(Timeout.timeout(1) { tiles.html("fill") }).to eq(described_class::NOT_DRAWN)
    drawer.join
  end

  it "gives a drawing past its bound an unknown note and draws the others", :aggregate_failures do
    tiles.refresh(1)
    expect(tiles.html("fill")).to include("did not answer in 0.1s")
    expect(tiles.html("train")).to eq("<p>train</p>")
  end

  it "hands a stream that joins the last drawings, drawing nothing" do
    expect(tiles.current(1).map(&:html)).to eq([described_class::NOT_DRAWN] * 2)
  end
end
