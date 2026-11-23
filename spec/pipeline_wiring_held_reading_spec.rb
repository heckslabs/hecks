# frozen_string_literal: true

require "spec_helper"
require "timeout"
require "hecks/pipeline_board/adapters/pipeline_wiring"

# A wiring source whose read waits to be released and says when it has begun.
HeldReadingSource = Struct.new(:stamps, :release, :entered) do
  def stamp = stamps.first

  def read
    entered << :reading
    release.pop
    Object.new
  end
end

# The Wiring lock while one reader rebuilds the graph: a stream that only wants to know whether the
# drawing moved is answered with the one it held, at once, and never queues behind the rebuild.
RSpec.describe Hecks::Adapters::PipelineWiring do
  let(:release) { Queue.new }
  let(:entered) { Queue.new }
  let(:stamps) { [0] }
  let(:source) { HeldReadingSource.new(stamps, release, entered) }

  let(:wiring) { described_class.new(registry: Object.new, settings: { source: source, look_seconds: 0 }) }

  before do
    graph = instance_double(Hecks::Adapters::PipelineBoard::Graph, to_h: { nodes: [], edges: [] })
    allow(Hecks::Adapters::PipelineBoard::Graph).to receive(:new).and_return(graph)
  end

  after { release << :go }

  it "answers the held digest at once while another reader rebuilds the graph" do
    held = wiring.reading[:digest]
    stamps[0] += 1
    Thread.new { wiring.reading }
    entered.pop(timeout: 2)
    expect(Timeout.timeout(1) { wiring.held_reading[:digest] }).to eq(held)
  end

  it "reads the digest itself when no other reader holds the lock" do
    expect(wiring.held_reading[:digest]).to eq(wiring.reading[:digest])
  end
end
