require "spec_helper"
require_relative "support/fill_stall_watches"

# The facts a watch of the fill answers: the counts, the idle minutes and the dominant reason with
# its reading and what governs it. The Delegate bluebook's `FillStall` policies decide from them.
RSpec.describe "the facts a watch of the fill answers" do
  include FillStallWatches

  let(:registry) { boot_hecks_in_memory.registry }

  after { FillStallWatches::DISPATCHING::Pending.reset! }

  def gauge(since: minutes_before(16), standing: 0)
    stall_dispatching(registry).gauge(run: { value: "beat-1" }, since: since, standing: { value: standing })
  end

  it "counts the waiting work, the free places and the minutes since the last start", :aggregate_failures do
    expect(gauge).to include(waiting: 1, room: 2, chosen: 0, idle_minutes: 16, standing: 0)
    expect(gauge[:now]).to eq("2026-11-20T10:00:00Z")
  end

  it "says the dominant reason, the reading behind it and what governs it" do
    expect(gauge).to include(reason: "1 held by load", reading: "load 22.8 from uptime against dispatch_max_load 10.0",
                             governed_by: "dispatch_max_load in the Tickets world")
  end

  it "counts what the plan would start once the load is calm" do
    stall_machine[:load] = 2.0

    expect(gauge).to include(chosen: 1, reason: "", reading: "")
  end

  it "names the owner's pause, under which the plan starts nothing" do
    stall_machine.merge!(load: 2.0, rolling: false)

    expect(gauge).to include(chosen: 0, reason: "1 held by owner pause")
  end

  it "answers no room under a full cap" do
    stall_machine[:started] = 7

    expect(gauge[:room]).to eq(0)
  end

  it "answers nothing waiting for an empty queue", :aggregate_failures do
    stall_machine[:planned] = 0

    expect(gauge).to include(waiting: 0, chosen: 0, reason: "")
  end

  it "counts no idle minutes before any time is recorded" do
    expect(gauge(since: "")).to include(idle_minutes: 0, since: "")
  end

  it "hands back the stall the record holds" do
    expect(gauge(standing: 1)[:standing]).to eq(1)
  end
end
