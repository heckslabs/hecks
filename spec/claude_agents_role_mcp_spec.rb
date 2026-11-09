require "spec_helper"
require "fileutils"
require "tmpdir"
require "hecks/hecks/adapters/claude_agents"

# A session started for a role whose rows name commands gets that role's MCP configuration, as a
# private file; any other session starts as it did. Against a stand-in for `claude` that records its
# arguments.
RSpec.describe "a dispatched session's MCP servers" do
  RECORDER = <<~SH.freeze
    #!/bin/sh
    printf '%s\\n' "$@" > "$(dirname "$0")/argv"
    printf 'backgrounded · session-id-abc123\\n'
  SH

  let(:scratch) { File.realpath(Dir.mktmpdir("claude-role-mcp")) }
  let(:files) { Dir.mktmpdir("claude-role-mcp-files") }
  let(:variables) { { "HECKS_SERVER_TOOLS" => "commands" } }
  let(:plans) do
    { "orchestrator" => { rows: true, variables: variables, unserved: [] },
      "reviewer"     => { rows: true, variables: {}, unserved: [] } }
  end
  let(:adapter) do
    Hecks::Adapters::ClaudeAgents.new(settings: { command: File.join(scratch, "claude"), server_env: server_env,
                                                  mcp_files: Hecks::Adapters::SessionConfigFile.new(directory: files) })
  end

  def server_env = ->(role, _repo) { plans.fetch(role, { rows: false, variables: {}, unserved: [] }) }

  def start(agent, run: "w1")
    @answer = adapter.start(repo: { value: scratch }, brief: { value: "go" }, agent: { value: agent }, run: { value: run })
    File.read(File.join(scratch, "argv")).split("\n")
  end

  def configuration(asked) = JSON.parse(File.read(asked[asked.index("--mcp-config") + 1]))

  before do
    File.write(File.join(scratch, "claude"), RECORDER)
    File.chmod(0o755, File.join(scratch, "claude"))
    File.write(File.join(scratch, ".mcp.json"), JSON.generate("mcpServers" => { "hecks-mcp" => { "command" => "ruby" } }))
  end

  after { FileUtils.rm_rf([scratch, files]) }

  it "starts the orchestrator with its restricted server, before the brief", :aggregate_failures do
    asked = start("orchestrator")
    expect(asked).to include("--mcp-config", "--strict-mcp-config")
    expect(asked.index("--strict-mcp-config")).to be < asked.index("--")
  end

  it "carries the role's variables in the configuration it passes" do
    expect(configuration(start("orchestrator")).dig("mcpServers", "hecks-mcp", "env")).to eq(variables)
  end

  it "puts a path on the command line, not the configuration", :aggregate_failures do
    asked = start("orchestrator")
    expect(asked[asked.index("--mcp-config") + 1]).to start_with(files)
    expect(asked.join(" ")).not_to include("HECKS_SERVER_TOOLS")
  end

  it "starts a role with no rows as before" do
    expect(start("coder")).to eq(%w[--agent coder --bg -- go])
  end

  it "starts a role with rows that name no command without hecks-mcp, and says so", :aggregate_failures do
    asked = start("reviewer")
    expect(configuration(asked)["mcpServers"]).to eq({})
    expect(@answer[:note][:value]).to include("hecks-mcp is not started")
  end

  it "answers no note when there is nothing to say" do
    start("orchestrator")
    expect(@answer).not_to have_key(:note)
  end

  it "removes the run's file with its session", :aggregate_failures do
    asked = start("orchestrator")
    path = asked[asked.index("--mcp-config") + 1]
    adapter.remove(session: { value: "session-id-abc123" }, run: { value: "w1" })
    expect(File.exist?(path)).to be(false)
  end
end
