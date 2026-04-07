# AI chapter self-description spec
#
# Verifies the AI chapter defines a domain with MCP tools,
# governance, IDE, and LLM aggregates.
#
require "spec_helper"
require "hecks/chapters/ai"

RSpec.describe Hecks::Chapters::AI do
  subject(:domain) { described_class.definition }

  it "builds a domain named AI" do
    expect(domain.name).to eq("AI")
  end

  it "includes key aggregates" do
    names = domain.aggregates.map(&:name)
    expect(names).to include("McpServer", "GovernanceGuard", "Server", "LlmClient")
  end

  it "includes McpConnection and DomainBuilder" do
    names = domain.aggregates.map(&:name)
    expect(names).to include("McpConnection", "DomainBuilder")
  end

  it "has at least 25 aggregates" do
    expect(domain.aggregates.size).to be >= 25
  end

  it "gives every aggregate at least one command" do
    domain.aggregates.each do |agg|
      expect(agg.commands).not_to be_empty, "#{agg.name} has no commands"
    end
  end

  it "every aggregate has a description" do
    domain.aggregates.each do |agg|
      expect(agg.description).not_to be_nil, "#{agg.name} has no description"
    end
  end

  it "defines Start and RegisterTools on McpServer" do
    mcp = domain.aggregates.find { |a| a.name == "McpServer" }
    expect(mcp.commands.map(&:name)).to include("Start", "RegisterTools")
  end
end
