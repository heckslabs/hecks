# frozen_string_literal: true

require_relative "../support/mcp_selection_checkout"
require "hecks/hecks/adapters/claude_agents"
require "hecks/hecks/adapters/claude_resumption"

# A resumed session carries the same settings, read from the run's own checkout.
RSpec.describe Hecks::Adapters::ClaudeResumption do
  let(:checkout) { McpSelectionCheckout.build }
  let(:shell) { instance_double(Hecks::Adapters::Shell) }
  let(:result) { Struct.new(:ok?, :out, :err).new(true, "backgrounded · abcdef1\n", "") }

  def resumed_words(agent)
    words = nil
    allow(shell).to receive(:capture) { |*args, **| (words = args) && result }
    described_class.new("claude", shell).call("abcdef1", { "sessionId" => "full-id", "state" => "stopped" }, "go",
                                              env: {}, chdir: checkout, agent: agent)
    words
  end

  after { FileUtils.remove_entry(checkout) }

  it "resumes a coder with the project servers disabled" do
    words = resumed_words("coder")
    expect(JSON.parse(words[words.index("--settings") + 1])["disabledMcpjsonServers"]).to match_array(McpSelectionCheckout::PROJECT)
  end

  it "resumes a session with no role with no settings" do
    expect(resumed_words(nil)).not_to include("--settings")
  end
end
