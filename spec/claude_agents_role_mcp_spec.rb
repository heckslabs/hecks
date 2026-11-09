require "spec_helper"
require "fileutils"
require "tmpdir"
require "hecks/hecks/adapters/claude_agents"

# A session started for a role whose rows name commands gets that role's MCP configuration; any
# other session starts as it did. Against a stand-in for `claude` that records its arguments.
RSpec.describe "a dispatched session's MCP servers" do
  RECORDER = <<~SH.freeze
    #!/bin/sh
    printf '%s\\n' "$@" > "$(dirname "$0")/argv"
    printf 'backgrounded · session-id-abc123\\n'
  SH

  let(:scratch) { File.realpath(Dir.mktmpdir("claude-role-mcp")) }
  let(:variables) { { "HECKS_SERVER_TOOLS" => "commands" } }
  let(:server_env) { ->(role) { role == "orchestrator" ? variables : {} } }
  let(:adapter) do
    Hecks::Adapters::ClaudeAgents.new(settings: { command: File.join(scratch, "claude"), server_env: server_env })
  end

  def start(agent)
    adapter.start(repo: { value: scratch }, brief: { value: "go" }, agent: { value: agent })
    File.read(File.join(scratch, "argv")).split("\n")
  end

  before do
    File.write(File.join(scratch, "claude"), RECORDER)
    File.chmod(0o755, File.join(scratch, "claude"))
    File.write(File.join(scratch, ".mcp.json"), JSON.generate("mcpServers" => { "hecks-mcp" => { "command" => "ruby" } }))
  end

  after { FileUtils.rm_rf(scratch) }

  it "starts the orchestrator with its restricted server, before the brief", :aggregate_failures do
    asked = start("orchestrator")
    expect(asked).to include("--mcp-config", "--strict-mcp-config")
    expect(asked.index("--strict-mcp-config")).to be < asked.index("--")
  end

  it "carries the role's variables in the configuration it passes" do
    asked = start("orchestrator")
    expect(JSON.parse(asked[asked.index("--mcp-config") + 1]).dig("mcpServers", "hecks-mcp", "env")).to eq(variables)
  end

  it "starts a role with no variables as before" do
    expect(start("coder")).to eq(%w[--agent coder --bg -- go])
  end
end
