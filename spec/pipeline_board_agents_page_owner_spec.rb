# frozen_string_literal: true

require "spec_helper"

# The agents page draws the owner on no line: a release cuts itself, and an owner-only ask is shown elsewhere.
RSpec.describe "the agents page comms diagram" do
  let(:html) { File.read(File.expand_path("../lib/hecks/pipeline_board/adapters/pipeline_web/agents.html", __dir__)) }
  let(:ends) { html.scan(/data-edge="[^"]+" data-ends="([^"]+)"/).flatten.map(&:split) }
  let(:nodes) { html.scan(/<g class="node" data-role="([^"]+)"/).flatten }

  it "ends no line at you" do
    expect(ends.select { |pair| pair.include?("you") }).to be_empty
  end

  it "draws no orchestrator or release manager node" do
    expect(nodes & %w[orchestrator release_manager]).to be_empty
  end

  it "keeps no you edge in EDGES" do
    edges = html[/const EDGES = \{.*?\n\};/m].scan(/(\w+): \["([\w-]+)", "([\w-]+)"\]/)
    expect(edges.select { |_, from, to| [from, to].include?("you") }.map(&:first)).to be_empty
  end
end
