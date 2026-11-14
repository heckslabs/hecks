require "spec_helper"
require "tmpdir"
require "hecks/hecks/adapters/dispatching"
require_relative "support/stall_watch_looks"

# A stall item whose run never starts is not a stall's subject, so no ladder of stall items grows,
# and a key is held to a length the ledger can bear.
RSpec.describe "StallWatch about stall items" do
  include_context "with a stall watch tap"

  def request(id, event = "AgentRunRequested")
    FileUtils.touch(tap)
    entry = line(File.readlines(tap).size + 1, event, id, 30).merge(aggregate: "Hecks::AgentRun")
    File.open(tap, "a") { |file| file.puts(JSON.generate(entry)) }
  end

  def stalls = watching.unclosed(run: "look").map { |row| row[:stall] }

  it "files the stall of a normal run" do
    request("red-train-1")

    expect(stalls).to eq(%w[stall-agent-run-start-red-train-1])
  end

  it "files no stall about a stall item's run" do
    request("stall-agent-run-session-red-train-1")

    expect(stalls).to be_empty
  end

  it "files one stall for a beat that sees a stall item's run beside a normal one" do
    request("stall-agent-run-session-red-train-1")
    request("red-train-2")
    detect("look-1")

    expect(keys("Tickets", "Work", :work)).to eq(%w[stall-agent-run-start-red-train-2])
  end

  it "holds a long key to 120 characters, the same each look", :aggregate_failures do
    request("red-#{"x" * 200}")

    expect(stalls.first.length).to eq(120)
    expect(stalls).to eq(watching.unclosed(run: "again").map { |row| row[:stall] })
  end

  it "keeps the stall's key a valid StallKey" do
    request("red-#{"x" * 200}")

    expect(stalls.first).to match(/\Astall-[a-z0-9-]+-[A-Za-z0-9._-]+\z/)
  end
end
