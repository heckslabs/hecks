require "spec_helper"
require "tmpdir"
require "hecks/hecks/adapters/dispatching"
require_relative "support/stall_watch_looks"

# Beats of the stall watch over one blocked coder run that is later tidied, each beat writing the
# Stall events it emitted to the tap by their own ids.
module BlockedRunLooks
  KEY = "stall-agent-run-blocked-lost".freeze

  def stall_beat(run)
    registry.repository("Hecks", registry.bluebook("Hecks").aggregate("Stall")).reset!
    before = registry.event_log.size
    detect(run)
    registry.event_log.drop(before).each { |event| tap_stall(event) }
  end

  def tap_stall(event)
    append_tap(event.name, event.id.to_s, "Hecks::Stall") if %w[StallFiled StallAbandoned].include?(event.name)
  end

  def blocked_then_tidied
    File.write(tap, "#{JSON.generate(line(1, "SessionBlocked", "lost", 20).merge(aggregate: "Hecks::AgentRun"))}\n")
    stall_beat("look-1")
    append_tap("AgentRunTidied", "lost", "Hecks::AgentRun")
    stall_beat("look-2")
  end

  def ids_of(name) = registry.event_log.select { |event| event.name == name }.map { |event| event.id.to_s }
end

# The beat that sights a blocked run files an agent-run-blocked stall and plans its work item; a
# later beat, after the run is tidied, abandons the stall and drops that same work item.
RSpec.describe "An agent-run-blocked stall whose run is tidied" do
  include_context "with a stall watch tap"
  include BlockedRunLooks

  it "files and abandons the stall under one key", :aggregate_failures do
    blocked_then_tidied

    expect(ids_of("StallFiled")).to eq([BlockedRunLooks::KEY])
    expect(ids_of("StallAbandoned")).to eq([BlockedRunLooks::KEY])
  end

  it "drops the work item the filed stall planned", :aggregate_failures do
    blocked_then_tidied

    expect(keys("Tickets", "Work", :work)).to eq([BlockedRunLooks::KEY])
    expect(keys("Tickets", "Work", :status)).to eq(%w[dropped])
  end
end
