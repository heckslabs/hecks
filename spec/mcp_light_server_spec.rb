require "spec_helper"
require_relative "support/mcp_light_helper"
require "hecks/adapters/driving/mcp"

# The MCP servers load the framework on their first tool call, not at start. What they answer
# before then is held to the replies the eager server gave (spec/fixtures/mcp_light), byte for byte.
RSpec.describe "the lazily loaded MCP servers" do
  include McpLightHelper

  McpLightHelper::MODES.each_key do |mode|
    it "answers #{mode} initialize, ping and tools/list as the eager server did, in this process" do
      expect(replies_in_process(mode)).to eq(golden(mode))
    end
  end

  %w[unrestricted readers].each do |mode|
    it "answers #{mode} in its own process as the eager server did, with no framework loaded", :aggregate_failures do
      out, probe = run_server(mode)
      expect(out).to eq(golden(mode))
      expect(probe[:framework]).to be(false)
    end
  end

  it "answers a commands server as the eager server did, loading the framework for its guide", :aggregate_failures do
    out, probe = run_server("commands")
    expect(out).to eq(golden("commands"))
    expect(probe[:framework]).to be(true)
  end

  it "holds well under the memory of a server that loaded the framework" do
    _, light = run_server("unrestricted")
    _, loaded = run_server("commands")
    expect(light[:rss_mb]).to be < loaded[:rss_mb] * 0.6
  end

  it "loads the framework on the first tool call" do
    call = { "jsonrpc" => "2.0", "id" => 4, "method" => "tools/call", "params" => { "name" => "domains", "arguments" => {} } }
    _, probe = run_server("unrestricted", [call])
    expect(probe[:framework]).to be(true)
  end

  it "serves the query-ir tools list without loading the framework", :aggregate_failures do
    out, probe = run_query_ir
    names = out.lines.last.then { |line| JSON.parse(line).dig("result", "tools").map { |tool| tool["name"] } }
    expect(names).to eq(%w[query_ir_constructs query_ir_duplicates query_ir_impact])
    expect(probe[:framework]).to be(false)
  end

  it "loads the framework for the first query-ir tool call" do
    call = { "jsonrpc" => "2.0", "id" => 6, "method" => "tools/call",
             "params" => { "name" => "query_ir_constructs", "arguments" => { "names" => ["Aggregate"] } } }
    _, probe = run_query_ir([call])
    expect(probe[:framework]).to be(true)
  end

  it "refuses a tool its scope does not serve without loading the framework", :aggregate_failures do
    call = { "jsonrpc" => "2.0", "id" => 5, "method" => "tools/call", "params" => { "name" => "dispatch", "arguments" => {} } }
    out, probe = run_server("readers", [call])
    expect(out).to include("is refused: this server runs in reader mode")
    expect(probe[:framework]).to be(false)
  end
end
