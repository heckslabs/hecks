require "spec_helper"
require "tmpdir"
require "hecks/hecks/adapters/dispatching"
require_relative "support/stall_watch_looks"

# Tap lines of one landing run, and the keys a look filed, for the landing-carry group.
module LandingCarryLooks
  RUN = "e0c1d2f3-0000-4000-8000-00000000a1b2".freeze

  def write_landing(rows)
    lines = rows.each_with_index.map { |(event, ago), seq| line(seq + 1, event, RUN, ago).merge(aggregate: "Delivery::Landing") }
    File.write(tap, lines.map { |entry| JSON.generate(entry) }.join("\n") << "\n")
  end

  def keys(domain, name, field)
    aggregate = registry.bluebook(domain).aggregate(name)
    registry.repository(domain, aggregate).all.map { |record| Hecks::Adapters::StartedWork.value(record, field).to_s }
  end

  def stall = "stall-landing-carry-#{RUN}"
end

# A landing job (`Landing.Carry`) that neither landed nor was refused within the `landing-carry`
# row's minutes (thirty: a healthy gate takes up to twenty, so ten filed a stall for a slow one and
# woke a session that resubmitted it) is a stall naming the run; landing or refusing closes it.
RSpec.describe "StallWatch landing-carry" do
  include_context "with a stall watch tap"
  include LandingCarryLooks

  {
    "a carry asked 2 minutes ago"  => [[["CarryRequested", 2]], false],
    "a carry asked 12 minutes ago" => [[["CarryRequested", 12]], false],
    "a carry asked 32 minutes ago" => [[["CarryRequested", 32]], true],
    "a carry that landed"          => [[["CarryRequested", 32], ["BranchLanded", 31]], false],
    "a carry that was refused"     => [[["CarryRequested", 32], ["LandingRefused", 31]], false]
  }.each do |name, (rows, filed)|
    it "files #{filed ? "a stall" : "nothing"} for #{name}" do
      write_landing(rows)
      detect("look-1")

      expect(keys("Hecks", "Stall", :stall)).to eq(filed ? [stall] : [])
    end
  end

  it "carries a move that checks the log and the gate process before anything else" do
    write_landing([["CarryRequested", 32]])

    expect(watching.unclosed(run: "look-1").first[:detail]).to include("hecks-landings", "gate process")
  end
end
