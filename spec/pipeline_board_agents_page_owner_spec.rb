# frozen_string_literal: true

require "spec_helper"

# The agents page draws the owner only where the owner acts: a release, and an owner-only ask.
RSpec.describe "the agents page comms diagram" do
  let(:html) { File.read(File.expand_path("../lib/hecks/pipeline_board/adapters/pipeline_web/agents.html", __dir__)) }
  let(:ends) { html.scan(/data-edge="[^"]+" data-ends="([^"]+)"/).flatten.map(&:split) }
  let(:nodes) { html.scan(/<g class="node" data-role="([^"]+)"/).flatten }

  it "ends no line at you except Release" do
    expect(ends.select { |pair| pair.include?("you") }).to eq([%w[you pipeline]])
  end

  it "draws no orchestrator or release manager node" do
    expect(nodes & %w[orchestrator release_manager]).to be_empty
  end

  it "keeps no you edge in EDGES except PassageReleased" do
    edges = html[/const EDGES = \{.*?\n\};/m].scan(/(\w+): \["([\w-]+)", "([\w-]+)"\]/)
    expect(edges.select { |_, from, to| [from, to].include?("you") }.map(&:first)).to eq(["PassageReleased"])
  end
end
