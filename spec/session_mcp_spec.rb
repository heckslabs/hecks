require "spec_helper"
require "fileutils"
require "tmpdir"
require "hecks/hecks/adapters/session_mcp"

# A role session's MCP servers: a copy of the checkout's `.mcp.json` whose `hecks-mcp` entry carries
# the role's variables, kept in a private file whose path goes to `claude`. A role that has routing
# rows never gets the checkout's unrestricted server; a role with none starts as before.
RSpec.describe Hecks::Adapters::SessionMcp do
  VARIABLES = { "HECKS_SERVER_TOOLS" => "commands", "HECKS_SERVER_DOMAINS" => "lib/hecks/hecks",
                "HECKS_SERVER_COMMANDS" => "dispatch.fill" }.freeze

  let(:repo) { Dir.mktmpdir("session-mcp") }
  let(:files) { Dir.mktmpdir("session-mcp-files") }
  let(:plan) { { rows: true, variables: VARIABLES, unserved: [] } }
  let(:config) do
    { "mcpServers" => { "hecks-query-ir" => { "command" => "ruby", "args" => %w[-I lib] },
                        "hecks-mcp"      => { "command" => "ruby", "args" => %w[-I lib] } } }
  end

  def write(json) = File.write(File.join(repo, ".mcp.json"), json)

  def mcp(answer = plan) = described_class.new(server_env: ->(_role, _repo) { answer }, files: file_store)

  def file_store = Hecks::Adapters::SessionConfigFile.new(directory: files)

  def started(agent: "orchestrator", answer: plan) = mcp(answer).call(repo: repo, agent: agent, run: "w1")

  def sent(result = started) = JSON.parse(File.read(result.flags[1]))

  after { FileUtils.rm_rf([repo, files]) }

  describe "a role whose rows name commands" do
    before { write(JSON.generate(config)) }

    it "passes the role's variables to the hecks-mcp entry and keeps the other server", :aggregate_failures do
      expect(sent["mcpServers"]["hecks-mcp"]["env"]).to eq(VARIABLES)
      expect(sent["mcpServers"]["hecks-query-ir"]).to eq(config["mcpServers"]["hecks-query-ir"])
    end

    it "uses only that configuration for the session" do
      expect(started.flags).to match(["--mcp-config", String, "--strict-mcp-config"])
    end

    it "passes a path only its owner can read, never the configuration itself", :aggregate_failures do
      path = started.flags[1]
      expect(File.stat(path).mode & 0o777).to eq(0o600)
      expect(started.flags.join).not_to include("HECKS_SERVER_COMMANDS")
    end

    it "keeps variables the entry already carries" do
      config["mcpServers"]["hecks-mcp"]["env"] = { "KEEP" => "1" }
      write(JSON.generate(config))
      expect(sent.dig("mcpServers", "hecks-mcp", "env")).to include("KEEP" => "1")
    end

    it "says nothing when every pattern names a command" do
      expect(started.notes).to eq([])
    end

    it "names the patterns the checkout's domain lacks" do
      lacking = plan.merge(unserved: ["Work.start!"])
      expect(started(answer: lacking).notes.join).to include("Work.start!")
    end

    it "says where the rows came from when the session's own checkout could not answer" do
      fallback = plan.merge(fallback: "Errno::ENOENT: no agents")
      expect(started(answer: fallback).notes.join).to include("dispatcher's checkout", "Errno::ENOENT")
    end
  end

  describe "a role with no rows, or no role" do
    before { write(JSON.generate(config)) }

    it "starts as before for a role with no rows" do
      expect(started(agent: "coder", answer: { rows: false, variables: {}, unserved: [] }).flags).to eq([])
    end

    it "starts as before for a bare empty set of variables" do
      expect(started(agent: "coder", answer: {}).flags).to eq([])
    end

    it "starts as before for a session with no role" do
      expect(started(agent: nil).flags).to eq([])
    end
  end

  describe "a role with rows that cannot be narrowed" do
    def servers(result) = sent(result)["mcpServers"]

    it "starts without hecks-mcp when the checkout has no .mcp.json", :aggregate_failures do
      result = started
      expect(servers(result)).to eq({})
      expect(result.notes.join).to include("hecks-mcp is not started", ".mcp.json is missing")
    end

    it "starts without hecks-mcp when the configuration cannot be read" do
      write("{ not json")
      expect(servers(started)).to eq({})
    end

    it "starts without hecks-mcp when the file is not an object" do
      write("[1, 2]")
      expect(servers(started)).to eq({})
    end

    it "starts without hecks-mcp, keeping the other server, when there is no such entry", :aggregate_failures do
      write(JSON.generate("mcpServers" => { "hecks-query-ir" => { "command" => "ruby" } }))
      result = started
      expect(servers(result).keys).to eq(["hecks-query-ir"])
      expect(result.notes.join).to include("no hecks-mcp entry")
    end

    it "starts without hecks-mcp when no row names a command", :aggregate_failures do
      write(JSON.generate(config))
      result = started(answer: plan.merge(variables: {}))
      expect(servers(result).keys).to eq(["hecks-query-ir"])
      expect(result.notes.join).to include("no routing row")
    end
  end

  describe "a checkout that cannot answer for the role" do
    it "falls back to the dispatcher's own rows and says so", :aggregate_failures do
      write(JSON.generate(config))
      result = described_class.new(files: file_store).call(repo: repo, agent: "orchestrator", run: "w1")
      expect(sent(result)["mcpServers"]["hecks-mcp"]["env"]).to include("HECKS_SERVER_TOOLS" => "commands")
      expect(result.notes.join).to include("dispatcher's checkout")
    end
  end

  describe "the file" do
    it "is removed with the run" do
      write(JSON.generate(config))
      path = started.flags[1]
      mcp.discard(run: "w1")
      expect(File.exist?(path)).to be(false)
    end

    it "is named for the run, and a second start replaces it" do
      write(JSON.generate(config))
      first = started.flags[1]
      expect(started.flags[1]).to eq(first)
    end
  end
end
