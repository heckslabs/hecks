# frozen_string_literal: true

require "spec_helper"
require_relative "support/pipeline_board_world"
require_relative "support/registry_store_spec_world"

# A slow load is kept for longer than the cache window, so it is not started again at once.
RSpec.describe Hecks::Adapters::PipelineBoard::RegistryStore, "#records" do
  include RegistryStoreSpecWorld

  let(:time) { [0.0] }
  let(:loads) { [] }

  it "keeps a slow load for ten times its length" do
    read_at(0.0, 60.0, registry: slow)
    expect(loads.size).to eq(1)
  end

  it "loads a slow aggregate again once ten times its length has passed" do
    read_at(0.0, 100.0, registry: slow)
    expect(loads.size).to eq(2)
  end

  it "keeps no load that failed" do
    read_at(0.0, 1.0, registry: slow(failing: true))
    expect(loads.size).to eq(2)
  end
end
