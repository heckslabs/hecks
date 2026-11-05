# frozen_string_literal: true

require "spec_helper"
require "hecks/pipeline_board/adapters/pipeline_wiring"

# The Hecks domain's `Board.Serve` asks the PipelineBoard domain to serve, so the board runs in the
# Hecks registry and its wiring page shows every attached bluebook, not only the one that served it.
RSpec.describe "Serving the pipeline board from the Hecks domain" do
  HECKS_DOMAIN_DIR = File.expand_path("../lib/hecks/hecks", __dir__)

  def self.hecks_registry = @hecks_registry ||= Hecks.describe(HECKS_DOMAIN_DIR).registry

  let(:registry) { self.class.hecks_registry }
  let(:board) { registry.bluebooks.fetch("Hecks") }

  it "attaches PipelineBoard to the Hecks registry", :aggregate_failures do
    expect(registry.bluebooks).to include("PipelineBoard")
    expect(board.aggregates.map(&:hecks_name)).to include("Board")
  end

  it "declares Board.Serve, which emits the event PipelineBoard reacts to" do
    board_aggregate = board.aggregates.find { |aggregate| aggregate.hecks_name == "Board" }
    serve = board_aggregate.commands.find { |command| command.hecks_name == "Serve" }
    expect(serve.emits).to include("BoardServeRequested")
  end

  it "reacts to Board.BoardServeRequested by running PipelineBoard's Serve", :aggregate_failures do
    policy = registry.bluebooks.fetch("PipelineBoard").policies.find { |p| p.name == "ServeWhenBoardRequested" }
    expect(policy.event_qualifier).to eq("Board")
    expect(policy.reaches).to eq("PipelineBoard.Serve")
  end

  it "draws every attached bluebook's aggregates on the wiring graph, not only the Hecks ones" do
    nodes = Hecks::Adapters::PipelineWiring.new(registry: registry).graph[:nodes]
    expect(nodes.map { |node| node[:id] }).to include(a_string_including("PipelineBoard"))
  end
end
