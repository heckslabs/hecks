require "spec_helper"
require "tmpdir"
require "hecks/hecks/adapters/dispatching"
require_relative "support/stall_watch_looks"

# Tap lines of a handed landing and the carry that follows it under a run of its own.
module LandingHandedLooks
  RUN = "e0c1d2f3-0000-4000-8000-00000000b2c3".freeze
  CARRY = "e0c1d2f3-0000-4000-8000-00000000d4e5".freeze

  # A handoff 12 minutes ago, then the event a minute later under the carry's own run.
  def self.then_carried(event) = [["LandingSubmitted", 12], [event, 11, CARRY]]

  def write_handoff(rows)
    lines = rows.each_with_index.map do |(event, ago, id), seq|
      line(seq + 1, event, id || RUN, ago).merge(aggregate: "Delivery::Landing")
    end
    File.write(tap, lines.map { |entry| JSON.generate(entry) }.join("\n") << "\n")
  end

  def filed_keys
    aggregate = registry.bluebook("Hecks").aggregate("Stall")
    registry.repository("Hecks", aggregate).all.map { |row| Hecks::Adapters::StartedWork.value(row, :stall).to_s }
  end
end

# A landing handed to a job that never began its carry within the `landing-handed` row's minutes
# is a stall naming the run; a carry (under its own run), a landing or a refusal closes it.
RSpec.describe "StallWatch landing-handed" do
  include_context "with a stall watch tap"
  include LandingHandedLooks

  {
    "a handoff 2 minutes ago"                  => [[["LandingSubmitted", 2]], false],
    "a handoff 12 minutes ago"                 => [[["LandingSubmitted", 12]], true],
    "a handoff followed by a carry of its own" => [LandingHandedLooks.then_carried("CarryRequested"), false],
    "a handoff followed by a landing"          => [LandingHandedLooks.then_carried("BranchLanded"), false],
    "a handoff followed by a refusal"          => [[["LandingSubmitted", 12], ["LandingRefused", 11]], false]
  }.each do |name, (rows, filed)|
    it "files #{filed ? "a stall" : "nothing"} for #{name}" do
      write_handoff(rows)
      detect("look-1")

      expect(filed_keys).to eq(filed ? ["stall-landing-handed-#{LandingHandedLooks::RUN}"] : [])
    end
  end

  it "carries a move that says a missing log proves nothing" do
    write_handoff([["LandingSubmitted", 12]])

    expect(watching.unclosed(run: "look-1").first[:detail]).to include("expected and proves nothing", "Work.release!")
  end
end
