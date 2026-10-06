require "spec_helper"
require "json"
require "stringio"
require "hecks/query_ir_mcp"

RSpec.describe Hecks::QueryIrMcp do
  def ask(*requests)
    output = StringIO.new
    described_class.serve(input: StringIO.new(requests.map { |request| "#{JSON.generate(request)}\n" }.join), output: output)
    output.string.lines.map { |line| JSON.parse(line) }
  end

  it "lists its three tools" do
    response = ask({ jsonrpc: "2.0", id: 1, method: "tools/list" }).first

    expect(response["result"]["tools"].map { |tool| tool["name"] })
      .to eq(%w[query_ir_constructs query_ir_duplicates query_ir_impact])
  end

  it "answers initialize, ping and an unknown method, and stays quiet for a notification" do
    responses = ask({ id: 1, method: "initialize" }, { method: "notifications/initialized" },
                    { id: 2, method: "ping" }, { id: 3, method: "no/such" })

    expect(responses.map { |response| response["id"] }).to eq([1, 2, 3])
    expect(responses.last["error"]["code"]).to eq(-32_601)
  end

  it "answers a tool call, and a refused one as an error result" do
    responses = ask({ id: 1, method: "tools/call", params: { name:      "query_ir_impact",
                                                             arguments: { name: "Aggregate", field: "preconditions" } } },
                    { id: 2, method: "tools/call", params: { name: "nothing" } })

    expect(responses.first["result"]["isError"]).to be false
    expect(responses.last["result"]["isError"]).to be true
  end

  it "answers a line that is not JSON with a parse error and keeps serving" do
    output = StringIO.new
    described_class.serve(input: StringIO.new("{\n#{JSON.generate(id: 1, method: "ping")}\n"), output: output)

    codes = output.string.lines.map { |line| JSON.parse(line) }

    expect(codes.first["error"]["code"]).to eq(-32_700)
    expect(codes.last["id"]).to eq(1)
  end

  it "refuses to start with an argument the guard does not accept" do
    reader, writer = IO.pipe

    expect { described_class.start(argv: ["--http"], input: reader, output: writer) }
      .to raise_error(SystemExit).and output(/refusing to start/).to_stderr
  ensure
    [reader, writer].each(&:close)
  end
end
