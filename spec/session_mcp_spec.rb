require "spec_helper"
require "fileutils"
require "tmpdir"
require "hecks/hecks/adapters/session_mcp"

# A role session's MCP servers: a copy of the checkout's `.mcp.json` whose `hecks-mcp` entry carries
# the role's variables, passed to `claude` as a string, with the checkout's own entries kept out.
RSpec.describe Hecks::Adapters::SessionMcp do
  VARIABLES = { "HECKS_SERVER_TOOLS" => "commands", "HECKS_SERVER_DOMAINS" => "lib/hecks/hecks",
                "HECKS_SERVER_COMMANDS" => "dispatch.fill" }.freeze

  let(:repo) { Dir.mktmpdir("session-mcp") }
  let(:config) do
    { "mcpServers" => { "hecks-query-ir" => { "command" => "ruby", "args" => %w[-I lib] },
                        "hecks-mcp"      => { "command" => "ruby", "args" => %w[-I lib] } } }
  end

  def write(json) = File.write(File.join(repo, ".mcp.json"), json)

  def mcp(variables = VARIABLES) = described_class.new(server_env: ->(_role) { variables })

  def flags(agent: "orchestrator") = mcp.arguments(repo: repo, agent: agent)

  after { FileUtils.rm_rf(repo) }

  it "passes the role's variables to the hecks-mcp entry and keeps the other server", :aggregate_failures do
    write(JSON.generate(config))
    sent = JSON.parse(flags[1])["mcpServers"]
    expect(sent["hecks-mcp"]["env"]).to eq(VARIABLES)
    expect(sent["hecks-query-ir"]).to eq(config["mcpServers"]["hecks-query-ir"])
  end

  it "uses only that configuration for the session" do
    write(JSON.generate(config))
    expect(flags).to match(["--mcp-config", String, "--strict-mcp-config"])
  end

  it "keeps variables the entry already carries" do
    config["mcpServers"]["hecks-mcp"]["env"] = { "KEEP" => "1" }
    write(JSON.generate(config))
    expect(JSON.parse(flags[1]).dig("mcpServers", "hecks-mcp", "env")).to include("KEEP" => "1")
  end

  it "passes nothing for a role with no variables" do
    write(JSON.generate(config))
    expect(mcp({}).arguments(repo: repo, agent: "coder")).to eq([])
  end

  it "passes nothing for a session with no role" do
    write(JSON.generate(config))
    expect(flags(agent: nil)).to eq([])
  end

  it "passes nothing where the checkout has no hecks-mcp entry to narrow", :aggregate_failures do
    expect(flags).to eq([])
    write(JSON.generate("mcpServers" => {}))
    expect(flags).to eq([])
  end

  it "passes nothing for a configuration it cannot read" do
    write("{ not json")
    expect(flags).to eq([])
  end
end
