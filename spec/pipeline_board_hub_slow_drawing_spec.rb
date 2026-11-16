# frozen_string_literal: true

require "spec_helper"
require_relative "support/fake_journal"
require "hecks/pipeline_board/adapters/pipeline_web"

# A drawing slower than the gap does not make the hub draw without a pause: the rest starts when
# a drawing ends and lasts at least as long as the drawing took, and one drawing never starts
# while another runs. The clock is a stand-in, so a five-second drawing costs no real time.
RSpec.describe Hecks::Adapters::PipelineBoard::Hub do
  let(:clock) do
    Class.new do
      def initialize = (@at = 0.0) && (@lock = Mutex.new)

      def now = @lock.synchronize { @at }

      def rest(seconds) = @lock.synchronize { @at += seconds }
    end.new
  end
  let(:journal) { FakeJournal.new }
  let(:spans) { Queue.new }
  let(:inside) { [0, 0] }
  let(:hub) do
    rows = [{ tile: "train", reads: "Hecks::SendTrain" }]
    tiles = Hecks::Adapters::PipelineBoard::Tiles.new(rows: rows, renderers: { "train" => -> { slow_drawing } })
    watch = Hecks::Adapters::PipelineBoard::Watch.new(path: "unused", source: -> { journal })
    described_class.new(tiles: tiles, watch: watch, net_seconds: 3600, gap: -> { 2 }, clock: clock).start
  end

  after { hub.stop }

  # A drawing that takes five seconds of the clock, counting how many run at once.
  def slow_drawing
    inside[1] = [inside[1], inside[0] += 1].max
    started = clock.now
    spans << [started, clock.rest(5)]
    inside[0] -= 1
    "<p>#{started}</p>"
  end

  # Ten journal lines, then every drawing made once the drawer has pushed its last one, in the
  # order they ended.
  def drawings_of_a_run
    reader = hub.join
    10.times { |seq| journal.push("aggregate" => "Hecks::SendTrain", "seq" => seq + 1) }
    nil while reader.pop(timeout: 0.5)
    Array.new(spans.size) { spans.pop }
  end

  it "rests after a slow drawing at least as long as the drawing took" do
    rests = drawings_of_a_run.each_cons(2).map { |(_, ended), (started, _)| started - ended }
    expect(rests).to all(be >= 5)
  end

  it "draws a run of lines at least once" do
    expect(drawings_of_a_run.size).to be_positive
  end

  it "never starts a drawing while another runs" do
    drawings_of_a_run
    expect(inside[1]).to eq(1)
  end

  it "draws nothing while the journal is idle" do
    hub.join.pop(timeout: 0.5)
    expect(spans.size).to eq(0)
  end
end
