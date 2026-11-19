require "spec_helper"
require "tmpdir"
require "hecks/hecks/adapters/dispatching"
require_relative "support/stall_watch_looks"

# Tap lines of coder runs a verdict could not reach: each line is an event on a run and its
# minutes ago.
module AnswerRefusedStallLooks
  # @param rows [Array<Array(String, String, Integer)>] each event, its run and its minutes ago
  def write_run_tap(*rows)
    lines = rows.each_with_index.map do |(event, run, ago), seq|
      line(seq + 1, event, run, ago).merge(aggregate: "Hecks::AgentRun")
    end
    File.write(tap, lines.map { |entry| JSON.generate(entry) }.join("\n") << "\n")
  end

  # @return [Array<String>] the stall keys filed
  def filed = keys("Hecks", "Stall", :stall)
end

# The StallWatch `agent-run-answer-refused` and `agent-run-unreached` rows file a verdict that no
# coder run could take at once, as `stall-<kind>-<run>`, so the orchestrator is woken; a later
# start of the run closes the line.
RSpec.describe "the refused-answer stalls" do
  include_context "with a stall watch tap"
  include AnswerRefusedStallLooks

  { "AnswerRefused" => "agent-run-answer-refused", "AgentRunUnreached" => "agent-run-unreached" }.each do |event, kind|
    it "files #{event} at once, naming the run" do
      write_run_tap([event, "run-1", 1])
      detect("look-1")

      expect(filed).to eq(["stall-#{kind}-run-1"])
    end

    it "files nothing once the run started again after #{event}" do
      write_run_tap([event, "run-1", 6], ["AgentRunStarted", "run-1", 2])
      detect("look-1")

      expect(filed).to be_empty
    end
  end
end
