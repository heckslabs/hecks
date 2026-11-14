# frozen_string_literal: true

require "spec_helper"
require "hecks/pipeline_board/adapters/pipeline_web"

# The owner's pruning switch on the board: what the board reads of the pruner's seat.
RSpec.describe Hecks::Adapters::PipelineBoard::PruningStanding do
  let(:board) { Hecks::Adapters::PipelineBoard }

  def store(*seats) = instance_double(board::RegistryStore, records: seats)

  def seat(status) = { role: "pruner", status: status }

  it "reads a paused seat as paused" do
    expect(described_class.of(store(seat("paused")))).to eq(state: "paused", status: "paused")
  end

  it "reads a resting or working seat as running", :aggregate_failures do
    expect(described_class.of(store(seat("resting")))[:state]).to eq("running")
    expect(described_class.of(store(seat("working")))[:state]).to eq("running")
  end

  it "reads no seat as unseated" do
    expect(described_class.of(store)).to eq(state: "unseated", status: "")
  end

  it "says why when the store cannot be read" do
    unread = instance_double(board::RegistryStore)
    allow(unread).to receive(:records).and_raise(board::Unavailable, "store closed")
    expect(described_class.of(unread)).to eq(unknown: "store closed")
  end
end
