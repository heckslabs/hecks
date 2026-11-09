require "spec_helper"
require_relative "support/mcp_light_helper"
require "hecks/adapters/driving/mcp"
require "hecks/query_ir_mcp"

# What the lazily loaded MCP servers refuse and survive. The refusals at start are held to what the
# eager server did (exit 2, nothing on stdout); a late load that fails is answered, once, and the
# server goes on.
RSpec.describe "the lazily loaded MCP servers' refusals and failures" do
  include McpLightHelper

  PING = { "jsonrpc" => "2.0", "id" => 7, "method" => "ping" }.freeze

  def replies(out) = out.lines.map { |line| JSON.parse(line) }

  describe "a setting the server refuses to start with" do
    {
      "a retired HECKS_DOOR_ name"     => [{ "HECKS_DOOR_TOOLS" => "readers" }, "retired"],
      "an unknown HECKS_SERVER_ name"  => [{ "HECKS_SERVER_NOPE" => "1" }, "HECKS_SERVER_NOPE"],
      "tools with no domains to serve" => [{ "HECKS_SERVER_TOOLS" => "readers" }, "needs HECKS_SERVER_DOMAINS"],
      "a domain outside the boot root" => [{ "HECKS_SERVER_TOOLS" => "readers", "HECKS_SERVER_DOMAINS" => "/etc" },
                                           "resolves outside"]
    }.each do |what, (env, words)|
      it "refuses #{what} with status 2, saying why, before anything reaches stdout", :aggregate_failures do
        out, err, status = run_raw(env, [])
        expect(status.exitstatus).to eq(2)
        expect(out).to be_empty
        expect(err).to include("refusing to start", words)
      end
    end
  end

  describe "what the server does with its input" do
    it "answers a notification with nothing" do
      out, = run_raw({}, [{ "jsonrpc" => "2.0", "method" => "notifications/initialized" }])
      expect(out).to be_empty
    end

    it "ends cleanly when stdin closes before any request", :aggregate_failures do
      out, _err, status = run_raw({}, "")
      expect(out).to be_empty
      expect(status.exitstatus).to eq(0)
    end

    it "answers a batch with one invalid-request error and goes on", :aggregate_failures do
      out, = run_raw({}, "#{JSON.generate([PING, PING])}\n#{JSON.generate(PING)}\n")
      first, second = replies(out)
      expect(first.dig("error", "code")).to eq(-32_600)
      expect(second).to eq("jsonrpc" => "2.0", "id" => 7, "result" => {})
    end

    it "answers a value that is not an object the same way" do
      out, = run_raw({}, "5\n")
      expect(replies(out).first.dig("error", "code")).to eq(-32_600)
    end
  end

  describe "a late load that failed" do
    let(:call) { { "jsonrpc" => "2.0", "id" => 9, "method" => "tools/call", "params" => { "name" => "domains" } } }
    let(:failure) { Hecks::McpLazyLoad::Failed.new("framework failed to load: SyntaxError: x.rb:1") }

    def server_with_failed_load
      mcp = Hecks::Adapters::Driving::Mcp
      mcp.instance_variable_set(:@scope, Hecks::Adapters::Driving::McpScope.from_env({}))
      mcp.instance_variable_set(:@load_state, { failure: failure })
      mcp
    end

    after do
      Hecks::Adapters::Driving::Mcp.instance_variable_set(:@scope, nil)
      Hecks::Adapters::Driving::Mcp.instance_variable_set(:@load_state, nil)
    end

    it "is answered with its own message as an internal error, on every call that needs the framework", :aggregate_failures do
      mcp = server_with_failed_load
      twice = capture_stdout { 2.times { mcp.handle_safely(call) } }
      errors = replies(twice).map { |reply| reply["error"] }
      expect(errors.map { |error| error["code"] }).to eq([-32_603, -32_603])
      expect(errors.map { |error| error["message"] }.uniq).to eq([failure.message])
    end

    it "does not answer a notification" do
      mcp = server_with_failed_load
      expect(capture_stdout { mcp.handle_safely(call.except("id")) }).to be_empty
    end

    def query_ir_error
      Hecks::QueryIrMcp.instance_variable_set(:@load_state, { failure: failure })
      out = StringIO.new
      Hecks::QueryIrMcp.respond({ "id" => 3, "method" => "tools/call", "params" => { "name" => "query_ir_constructs" } }, out)
      JSON.parse(out.string)["error"]
    ensure
      Hecks::QueryIrMcp.instance_variable_set(:@load_state, nil)
    end

    it "answers the query-ir server the same way" do
      expect(query_ir_error["message"]).to eq(failure.message)
    end
  end

  describe Hecks::McpLazyLoad do
    def run_failing(memo, error, counter)
      described_class.run(memo) { (counter << 1) && raise(error) }
    rescue described_class::Failed => e
      e
    end

    def fail_twice
      counter = []
      memo = {}
      [run_failing(memo, SyntaxError.new("broken"), counter), run_failing(memo, LoadError.new("again"), counter), counter]
    end

    it "turns a load error that is not a StandardError into a failure" do
      expect(fail_twice.first.message).to eq("framework failed to load: SyntaxError: broken")
    end

    it "remembers the failure, and does not run the load again", :aggregate_failures do
      first, second, counter = fail_twice
      expect(second.message).to eq(first.message)
      expect(counter.size).to eq(1)
    end

    it "loads once and then does nothing", :aggregate_failures do
      memo = {}
      loads = []
      2.times { described_class.run(memo) { loads << 1 } }
      expect(loads.size).to eq(1)
      expect(memo[:done]).to be(true)
    end
  end
end
