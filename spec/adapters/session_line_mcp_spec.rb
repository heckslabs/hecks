# frozen_string_literal: true

require_relative "../support/mcp_selection_checkout"
require "hecks/hecks/adapters/session_line"

# A session's start command carries the project servers its role does not start.
RSpec.describe Hecks::Adapters::SessionLine do
  let(:checkout) { McpSelectionCheckout.build }

  def words_for(agent)
    described_class.new(command: "claude", nice: []).arguments({ run: "r1", agent: agent, brief: "b", repo: checkout })
  end

  def disabled(agent) = JSON.parse(words_for(agent)[words_for(agent).index("--settings") + 1])["disabledMcpjsonServers"]

  after { FileUtils.remove_entry(checkout) }

  it "starts a coder session with no project MCP server" do
    expect(disabled("coder")).to match_array(McpSelectionCheckout::PROJECT)
  end

  it "disables both project servers for a fill-started coder that names no agent" do
    run = { run: "r1", works_as: "coder", brief: "b", repo: checkout }
    words = described_class.new(command: "claude", nice: []).arguments(run)
    expect(JSON.parse(words[words.index("--settings") + 1])["disabledMcpjsonServers"]).to match_array(McpSelectionCheckout::PROJECT)
  end

  it "starts the architect as its role, whose file brings the Hecks door, with no project server", :aggregate_failures do
    expect(words_for("architect").each_cons(2)).to include(["--agent", "architect"])
    expect(disabled("architect")).to match_array(McpSelectionCheckout::PROJECT)
  end
end
