require "spec_helper"
require "tmpdir"
require "fileutils"
require_relative "support/mcp_light_helper"
require "hecks/adapters/driving/mcp"
require "hecks/role_server_cache"

# An MCP server narrows itself to what its session's role may do, from the `CLAUDE_CODE_AGENT`
# variable Claude Code gives every server it starts. A resumed session cannot be given flags, so
# this is the one restriction that survives a resume. The checkout the server serves is a scratch
# copy (HECKS_STOREHOUSE_ROOT), so no example boots the real Hecks domain or opens a live ledger.
RSpec.describe "an MCP server that learns its restriction from the agent it serves" do
  include McpLightHelper

  let(:checkout) { Dir.mktmpdir("role-scope-checkout") }
  let(:cache_home) { Dir.mktmpdir("role-scope-cache") }
  let(:driving) { Hecks::Adapters::Driving }
  let(:tables) { { "orchestrator" => ["order.create_pizza"], "closed" => [] } }

  before do
    build_checkout
    @saved = ENV.fetch("XDG_CACHE_HOME", nil)
    ENV["XDG_CACHE_HOME"] = cache_home
    Hecks::CacheDir.reset!
  end

  after do
    ENV["XDG_CACHE_HOME"] = @saved
    Hecks::CacheDir.reset!
    [checkout, cache_home].each { |dir| FileUtils.remove_entry(dir) }
  end

  def build_checkout
    FileUtils.mkdir_p(File.join(checkout, "lib/hecks/agents"))
    FileUtils.mkdir_p(File.join(checkout, "lib/hecks"))
    File.write(File.join(checkout, "lib/hecks/agents/agents.bluebook"), "rows")
    File.write(File.join(checkout, "lib/hecks/version.rb"), "VERSION = 1")
    FileUtils.cp_r(File.join(repo_root, "examples/pizzas"), File.join(checkout, "lib/hecks/hecks"))
  end

  def cached = Hecks::RoleServerCache.write(checkout, tables)

  def served(role, extra = {}, requests = McpLightHelper::REQUESTS)
    env = { "HECKS_STOREHOUSE_ROOT" => checkout, "XDG_CACHE_HOME" => cache_home, "CLAUDE_CODE_AGENT" => role }.merge(extra)
    out, err, = run_raw(env, requests)
    [out, probe_of(err)]
  end

  def names(out) = JSON.parse(out.lines.last).dig("result", "tools").map { |tool| tool["name"] }

  def call(name)
    [{ "jsonrpc" => "2.0", "id" => 9, "method" => "tools/call", "params" => { "name" => name, "arguments" => {} } }]
  end

  it "answers initialize and ping from a cached role without loading the framework", :aggregate_failures do
    cached
    out, probe = served("orchestrator", {}, McpLightHelper::REQUESTS.first(2))
    expect(out.lines.size).to eq(2)
    expect(probe[:framework]).to be(false)
  end

  it "serves a role with rows the reader tools and dispatch, and nothing else" do
    cached
    out, = served("orchestrator")
    expect(names(out)).to match_array(driving::McpScope::COMMAND_TOOLS)
  end

  it "serves a role whose rows name no command no tool, and loads nothing", :aggregate_failures do
    cached
    out, probe = served("closed")
    expect(names(out)).to eq([])
    expect(probe[:framework]).to be(false)
  end

  it "refuses every call of such a role by name" do
    cached
    out, = served("closed", {}, call("state"))
    expect(JSON.parse(out)["result"]["content"].first["text"]).to include("no commands for role closed")
  end

  it "leaves a role with no rows unrestricted" do
    cached
    out, = served("coder")
    expect(names(out)).to eq(driving::Mcp::TOOLS.map { |tool| tool[:name] })
  end

  it "leaves a session with no agent unrestricted", :aggregate_failures do
    cached
    out, probe = served(nil)
    expect(names(out)).to eq(driving::Mcp::TOOLS.map { |tool| tool[:name] })
    expect(probe[:framework]).to be(false)
  end

  it "lets an explicit HECKS_SERVER_* setting win over the agent" do
    cached
    out, = served("closed", { "HECKS_SERVER_TOOLS" => "readers", "HECKS_SERVER_DOMAINS" => "lib/hecks/hecks" })
    expect(names(out)).to match_array(driving::McpScope::READER_TOOLS)
  end

  it "still refuses an explicit setting that is wrong, whatever the agent" do
    cached
    _, err, status = run_raw({ "HECKS_STOREHOUSE_ROOT" => checkout, "CLAUDE_CODE_AGENT" => "orchestrator",
                               "HECKS_SERVER_TOOLS" => "commands" })
    expect([status.exitstatus, err]).to match([2, /needs HECKS_SERVER_DOMAINS/])
  end

  it "serves no tool when the rows cannot be read, instead of every tool", :aggregate_failures do
    out, probe = served("orchestrator")
    expect(names(out)).to eq([])
    expect(probe[:framework]).to be(true)
  end

  it "refuses every call of a role whose rows cannot be read, naming why they could not be" do
    out, = served("orchestrator", {}, call("state"))
    expect(JSON.parse(out)["result"]["content"].first["text"]).to include("routing rows could not be read")
  end

  it "does not write a table it could not work out" do
    served("orchestrator")
    expect(Dir.glob(File.join(cache_home, "hecks/role-servers/*.json"))).to eq([])
  end

  it "does not reuse a table after the agents bluebook changes" do
    cached
    File.write(File.join(checkout, "lib/hecks/agents/agents.bluebook"), "rows changed")
    out, = served("orchestrator")
    expect(names(out)).to eq([])
  end
end
