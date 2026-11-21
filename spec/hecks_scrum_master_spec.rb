require "spec_helper"
require "tmpdir"
require "hecks/hecks/adapters/dispatching"
require_relative "support/help_wanted_looks"
require_relative "support/role_file_slices"

# The scrum master wakes on the beat when the impediment view holds a row nobody has called for
# help with, raises the call with its evidence, and its marks stand as draft charter lines.
RSpec.describe "the scrum master" do
  include_context "with a stall watch tap"
  include HelpWantedLooks
  include RoleFileSlices

  let(:hold) { ["BoardingHoldSettled", "hold-1", 15, "Hecks::BoardingHold"] }

  def unraised = watching.unraised(run: "look-1").map { |row| row[:impediment] }

  it "lists an impediment no call for help or wake has met" do
    write_sources([hold])
    expect(unraised).to eq([HelpWantedLooks::HOLD])
  end

  it "leaves an impediment whose call for help stands" do
    write_sources([hold, ["HelpWantedRaised", "help-#{HelpWantedLooks::HOLD}", 1, "Hecks::HelpWanted"]])
    expect(unraised).to be_empty
  end

  it "leaves an impediment it already woke a run for, so a failed wake is not repeated every beat" do
    write_sources([hold, ["AgentRunRequested", HelpWantedLooks::HOLD, 1, "Hecks::AgentRun"]])
    expect(unraised).to be_empty
  end

  it "wakes one run of the scrum master, keyed by the impediment, on the beat" do
    write_sources([hold])
    detect("look-1")

    expect(keys("Hecks", "AgentRun", :run)).to eq([HelpWantedLooks::HOLD])
  end

  it "names the scrum master among the roles, with its file", :aggregate_failures do
    expect(world_roles).to include("scrum-master")
    expect(File).to exist(File.join(RoleFileSlices::AGENTS, "scrum-master.md"))
  end

  it "may raise a call for help and may not land a branch", :aggregate_failures do
    allowed = routing.select { |row| row[:role] == "scrum-master" }.map { |row| row[:pattern] }

    expect(allowed).to include("HelpWanted.raise!", "StallWatch.impediments")
    expect(allowed).not_to include("Landing.land!", "AgentRun.answer!")
  end

  it "declares its marks as draft charter lines", :aggregate_failures do
    lines = draft_lines.to_h { |row| [row[:theme], row[:mark]] }

    expect(lines).to eq("landings an hour" => 6, "reds, one landing in" => 10, "minutes to answer a block" => 15)
  end

  def routing
    role.value_objects.find { |object| object.hecks_name == "RoutingRule" }.members
  end

  def role
    bluebook = Hecks.describe(File.join(InMemoryDomain::ROOT, "lib/hecks/agents")).registry.bluebooks.fetch("Agents")
    bluebook.aggregates.find { |aggregate| aggregate.hecks_name == "Role" }
  end

  def draft_lines
    tickets = Hecks.describe(File.join(InMemoryDomain::ROOT, "lib/hecks/tickets")).registry.bluebooks.fetch("Tickets")
    epic = tickets.aggregates.find { |aggregate| aggregate.hecks_name == "Epic" }
    epic.value_objects.find { |object| object.hecks_name == "DraftCharterLine" }.members
  end
end
