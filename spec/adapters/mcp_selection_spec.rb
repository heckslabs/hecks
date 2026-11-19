# frozen_string_literal: true

require_relative "../support/mcp_selection_checkout"
require "hecks/hecks/adapters/mcp_selection"

# A session starts only the project MCP servers its role file's tools name.
RSpec.describe Hecks::Adapters::McpSelection do
  let(:checkout) { McpSelectionCheckout.build }

  def disabled(agent) = described_class.settings(checkout, agent).fetch(described_class::KEY, [])

  after { FileUtils.remove_entry(checkout) }

  it "disables every project server for a coder and for the architect, whose door is its own" do
    expect([disabled("coder"), disabled("architect")]).to all(match_array(McpSelectionCheckout::PROJECT))
  end

  it "keeps a project server the role's tools name, whole or by one of its tools" do
    McpSelectionCheckout.role(checkout, "helper", "tools: Read, mcp__hecks-mcp, mcp__hecks-query-ir__query_ir_impact")
    expect(disabled("helper")).to be_empty
  end

  it "disables nothing for a role whose tools are every tool or that has no tools line" do
    McpSelectionCheckout.role(checkout, "owner", "tools: *")
    McpSelectionCheckout.role(checkout, "open", "model: sonnet")
    expect([disabled("owner"), disabled("open")]).to all(be_empty)
  end

  it "disables nothing for a session with no role or no role file" do
    expect([disabled(nil), disabled("nobody")]).to all(be_empty)
  end

  it "disables nothing when the checkout has no .mcp.json" do
    File.delete(File.join(checkout, ".mcp.json"))
    expect(disabled("coder")).to be_empty
  end
end
