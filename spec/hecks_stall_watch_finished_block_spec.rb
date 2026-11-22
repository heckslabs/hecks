require "spec_helper"
require "tmpdir"
require_relative "support/stall_watch_looks"

# Tap lines of one run that blocked, had its stall filed, and then finished stopped, read against
# the bluebook's own `agent-run-blocked` row: a finished run waits on nothing.
module FinishedBlockLooks
  RUN = "ad52223c-65e3-41c7-86a8-6455cbe5ef7a".freeze

  def stall = "stall-agent-run-blocked-#{RUN}"

  # The run blocked 30 minutes ago, its stall was filed 14 minutes ago, and it finished 10 ago.
  def write_finished_block(ending: "SessionFinished")
    rows = [["Hecks::AgentRun", "SessionBlocked", RUN, 30], ["Hecks::Stall", "StallFiled", stall, 14],
            ["Hecks::AgentRun", ending, RUN, 10]]
    entries = rows.each_with_index.map do |(aggregate, event, id, ago), seq|
      line(seq + 1, event, id, ago).merge(aggregate: aggregate)
    end
    File.write(tap, entries.map { |entry| JSON.generate(entry) }.join("\n") << "\n")
  end
end

RSpec.describe "StallWatch agent-run-blocked on a finished run" do
  include_context "with a stall watch tap"
  include FinishedBlockLooks

  it "abandons the open stall of a run that finished, naming the finish" do
    write_finished_block
    expect(watching.abandoned(run: "look-1").map { |row| [row[:stall], row[:reason]] })
      .to contain_exactly([stall, a_string_including("SessionFinished")])
  end

  it "abandons the open stall of a run that failed, naming the failure" do
    write_finished_block(ending: "SessionFailed")
    expect(watching.abandoned(run: "look-1").map { |row| row[:reason] })
      .to contain_exactly(a_string_including("SessionFailed"))
  end

  it "lists no impediment for a run that finished" do
    write_finished_block
    expect(watching.impediments(run: "look-1")).to be_empty
  end
end
