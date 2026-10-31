require "spec_helper"
require "stringio"
require "json"
require "hecks/adapters/driving/mcp"

# Progress over MCP: with a progress token, each stage line of a call goes out as a
# notifications/progress message before the call's response; without one, nothing is sent.
RSpec.describe "MCP progress" do
  let(:door) { Hecks::Adapters::Driving::Mcp }
  let(:out)  { StringIO.new }

  # A tool that runs one stage through the call's progress seam, then answers.
  def staged_tool(_name, _args)
    seam = door.progress
    seam&.start("first")
    seam&.finish("first", true, 0.1)
    { ok: true }
  end

  # Runs a tools/call with an optional progress token, capturing stdout.
  def call(token)
    params = { "name" => "dispatch", "arguments" => {} }
    params["_meta"] = { "progressToken" => token } if token
    allow(door).to receive(:answer_tool) { |name, args| staged_tool(name, args) }
    original = $stdout
    $stdout = out
    door.tools_call(params)
  ensure
    $stdout = original if original
  end

  def messages = out.string.lines.map { |line| JSON.parse(line) }

  it "sends the stage lines as progress notifications, in order" do
    call("tok-1")
    expect(messages.map { |m| m.dig("params", "message") }).to eq(["start first", "ok first 0.1s"])
  end

  it "echoes the client's token and counts the lines" do
    call("tok-1")
    pairs = messages.map { |m| [m.dig("params", "progressToken"), m.dig("params", "progress")] }
    expect(pairs).to eq([["tok-1", 1], ["tok-1", 2]])
  end

  it "sends nothing without a progress token" do
    call(nil)
    expect(out.string).to be_empty
  end

  it "returns the same result with or without a token" do
    expect(call("tok-1")).to eq(call(nil))
  end
end
