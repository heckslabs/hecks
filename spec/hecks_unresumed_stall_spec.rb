require "spec_helper"
require "tmpdir"
require "hecks/hecks/adapters/dispatching"
require_relative "support/stall_watch_looks"

# Tap lines of coder runs whose verdict's resume was refused: each line is an event on a run and its
# minutes ago.
module UnresumedStallLooks
  # @param rows [Array<Array(String, String, Integer)>] each event, its run and its minutes ago
  def write_run_tap(*rows)
    lines = rows.each_with_index.map do |(event, run, ago), seq|
      line(seq + 1, event, run, ago).merge(aggregate: "Hecks::AgentRun")
    end
    File.write(tap, lines.map { |entry| JSON.generate(entry) }.join("\n") << "\n")
  end

  def filed = keys("Hecks", "Stall", :stall)
end

# The StallWatch `agent-run-unresumed` row files a run whose refused resume stayed open ten minutes
# as `stall-agent-run-unresumed-<run>`; the run's answer or its end closes it.
RSpec.describe "the unresumed-verdict stall" do
  include_context "with a stall watch tap"
  include UnresumedStallLooks

  it "files a refused resume left open ten minutes, naming the run" do
    write_run_tap(["AgentRunUnresumed", "run-1", 12])
    detect("look-1")

    expect(filed).to eq(%w[stall-agent-run-unresumed-run-1])
  end

  it "files nothing for a refusal younger than ten minutes" do
    write_run_tap(["AgentRunUnresumed", "run-1", 4])
    detect("look-1")

    expect(filed).to be_empty
  end

  it "files one stall, aged from the first line, when the refusal repeats" do
    write_run_tap(["AgentRunUnresumed", "run-1", 12], ["AgentRunUnresumed", "run-1", 2])
    detect("look-1")

    expect(filed).to eq(%w[stall-agent-run-unresumed-run-1])
  end

  %w[AgentRunAnswered SessionFinished].each do |closing|
    it "files nothing once #{closing} closed the run's line" do
      write_run_tap(["AgentRunUnresumed", "run-1", 12], [closing, "run-1", 6])
      detect("look-1")

      expect(filed).to be_empty
    end
  end
end
