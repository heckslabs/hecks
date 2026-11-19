require "spec_helper"
require "tmpdir"
require_relative "support/stall_watch_looks"

# Tap lines of one reviewer run that blocked and was then tidied at its landing, read against the
# bluebook's own `agent-run-blocked` row: a tidied run waits on nothing.
module TidiedBlockLooks
  # The run, keyed as a reviewer's run is: its branch tip.
  RUN = "48a816ba9b41614126e3959e92b00d9159eac7a0".freeze

  def stall = "stall-agent-run-blocked-#{RUN}"

  # The run blocked 30 minutes ago with no question; `filed` adds the stall a look filed for it,
  # and the run is tidied 10 minutes ago.
  def write_tidied_block(filed: false)
    rows = [["Hecks::AgentRun", "SessionBlocked", RUN, 30]]
    rows << ["Hecks::Stall", "StallFiled", stall, 14] if filed
    rows << ["Hecks::AgentRun", "AgentRunTidied", RUN, 10]
    entries = rows.each_with_index.map do |(aggregate, event, id, ago), seq|
      line(seq + 1, event, id, ago).merge(aggregate: aggregate)
    end
    File.write(tap, entries.map { |entry| JSON.generate(entry) }.join("\n") << "\n")
  end
end

RSpec.describe "StallWatch agent-run-blocked on a tidied run" do
  include_context "with a stall watch tap"
  include TidiedBlockLooks

  it "files no stall for a run tidied after it blocked" do
    write_tidied_block
    expect(watching.unclosed(run: "look-1")).to be_empty
  end

  it "abandons the open stall of a run tidied after it blocked, naming the tidy" do
    write_tidied_block(filed: true)
    expect(watching.abandoned(run: "look-1").map { |row| [row[:stall], row[:reason]] })
      .to contain_exactly([stall, a_string_including("AgentRunTidied")])
  end

  it "lists no impediment for a run tidied after it blocked" do
    write_tidied_block(filed: true)
    expect(watching.impediments(run: "look-1")).to be_empty
  end
end
