require "spec_helper"
require "hecks/harness/run"
require_relative "support/hecks_harness_binary"

# Every role of the crew opens as a Harness session, briefed from its role file and holding the
# tools that file names. Each session plays the same tape, crew_member in rust/harness/tests/tapes:
# it checks the brief says how mail works, then asks for Bash, Edit and a reviewer subagent, and
# the supervisor allows each one the role names and refuses the rest. The owner's own
# orchestrator, which names every tool, is started by hand and not opened.
module HarnessCrewWorld
  TAPES = File.join(HecksHarnessBinary::DIR, "tests/tapes")
  OWNERS = %w[orchestrator-owner].freeze
  ASKED = %w[Bash Edit Agent].freeze

  # @return [Array<String>] the roles a harness run opens
  def self.crew = Hecks::Harness::Roles.names - OWNERS

  # Opens every role, each on the crew member's tape, and reads the ledger once all have answered.
  #
  # @return [Hecks::Harness::Run] the run, closed
  def self.opened
    @opened ||= begin
      launch = Hecks::Harness::Launch.replay(TAPES, tapes: crew.to_h { |role| [role, "crew_member"] })
      run = Hecks::Harness::Run.new(launch: Hecks::Harness::Launch.crew(launch))
      crew.each { |role| run.open_role(role) }
      run.pump { |tells| tells.count { |tell| tell["tell"] == "turn_ended" } == crew.size }
      run.tap(&:close)
    end
  end

  # @return [Hash{String => Array<String>}] each role, to the tools it asked for and was allowed
  def self.allowed = answered("ToolAllowed")

  # @return [Hash{String => Array<String>}] each role, to the tools it asked for and was refused
  def self.withheld = answered("ToolWithheld")

  def self.answered(name)
    found = opened.runtime.events.select { |event| event.name == name }
    crew.to_h { |role| [role, found.select { |event| event.id == role }.map { |event| event.payload[:tool][:value] }] }
  end
end

RSpec.describe "Every role of the crew as a Harness session", :io do
  include_context "with the hecks-harness binary"

  it "opens every role but the owner's own orchestrator" do
    expect(HarnessCrewWorld.crew).to eq(%w[architect coder orchestrator planner product-owner pruner reviewer
                                           scrum-master staff-engineer])
  end

  it "allows each role the shell, which every role file names" do
    expect(HarnessCrewWorld.allowed.values).to all(include("Bash"))
  end

  it "allows the coder its edits, and refuses them to every other role" do
    expect(HarnessCrewWorld.allowed.select { |_, tools| tools.include?("Edit") }.keys).to eq(%w[coder])
  end

  it "lets only the reviewer start a reviewer subagent" do
    expect(HarnessCrewWorld.allowed.select { |_, tools| tools.include?("Agent") }.keys).to eq(%w[reviewer])
  end

  it "answers every tool each role asked for, once" do
    answered = HarnessCrewWorld.crew.map { |role| (HarnessCrewWorld.allowed[role] + HarnessCrewWorld.withheld[role]).sort }
    expect(answered).to all(eq(HarnessCrewWorld::ASKED.sort))
  end

  it "refuses to open the owner's own orchestrator, which names every tool" do
    expect { Hecks::Harness::Roles.role("orchestrator-owner") }
      .to raise_error(Hecks::Harness::Roles::Unbriefed, /started by hand by an owner/)
  end

  it "reads a role's tools and model from its file" do
    expect(Hecks::Harness::Roles.role("coder").to_h.slice(:tools, :model))
      .to eq(tools: %w[Read Edit Write Grep Glob Bash Agent(Explore)], model: "sonnet")
  end
end
