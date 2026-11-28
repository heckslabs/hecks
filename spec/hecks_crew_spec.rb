# frozen_string_literal: true

require "spec_helper"
require "fileutils"
require "tmpdir"
require "hecks/hecks/adapters/crew_harness"
require_relative "support/hecks_harness_binary"

# One command, `Crew.up!`, brings up a checkout's crew: every role but the owner's own orchestrator
# opens as a session of one Harness run, on its brief and tools, until the crew is stopped. The
# checkout here is a fixture, spec/fixtures/harness_roles. Each role's child plays the crew member's
# tape (rust/harness/tests/tapes), copied under the role's name, and the crew is stopped after one
# turn of every session, so no model runs.
module HecksCrewWorld
  TAPE = File.join(HecksHarnessBinary::DIR, "tests/tapes/crew_member.jsonl")
  CHECKOUT = File.expand_path("fixtures/harness_roles", __dir__)

  module_function

  # @param roles [Array<String>] the roles given a tape
  # @return [String] a new directory holding the crew member's tape once for each role
  def tapes(roles)
    Dir.mktmpdir("crew-tapes").tap do |dir|
      roles.each { |role| FileUtils.cp(TAPE, File.join(dir, "#{role}.jsonl")) }
    end
  end

  # @return [Array<String>] the roles brought up
  def crew = Hecks::Harness::Roles.crew(root: CHECKOUT)

  # Brings the crew up through the command, as the Maintainer, in a booted Hecks.
  #
  # @return [Hash] the Crew record as the ledger holds it, each value object as its value
  def up(hecks, run, tapes, checkout: CHECKOUT)
    Hecks::Runtime::Caller.as(role: "Maintainer") do
      hecks.dispatch_flat("Hecks::Crew.Up", run: { value: run }, checkout: { value: checkout }, tapes: { value: tapes },
                                            turns: { value: 1 })
    end
    record(hecks, run)
  end

  def record(hecks, run)
    registry = hecks.registry
    found = registry.repository("Hecks", registry.bluebook("Hecks").aggregate("Crew")).find(run)
    Hecks::Runtime::Value.materialize(found.state).transform_values { |value| value.is_a?(Hash) ? value[:value] : value }
  end
end

RSpec.describe "One command brings up the crew", :io do
  include_context "with the hecks-harness binary"

  before(:all) { @hecks = boot_hecks_in_memory }

  let(:roles) { HecksCrewWorld.crew }
  let(:tapes) { HecksCrewWorld.tapes(roles) }

  after { FileUtils.rm_rf(tapes) }

  it "brings up every role but the owner's own orchestrator" do
    expect(roles).to eq(%w[coder reviewer scrum-master staff-engineer])
  end

  it "ends the crew once every session has ended its turn, naming the sessions it brought up" do
    expect(HecksCrewWorld.up(@hecks, "crew-1", tapes))
      .to include(status: "ended", last: "brought up 4 sessions (#{roles.join(", ")}); stopped after 1 turn of every session")
  end

  it "refuses the crew of a checkout with no role files" do
    expect(HecksCrewWorld.up(@hecks, "crew-3", tapes, checkout: tapes)).to include(status: "refused", last: /cannot read/)
  end

  it "asks for the crew when the command is given none of its optional arguments" do
    Hecks::Runtime::Caller.as(role: "Maintainer") do
      @hecks.dispatch_flat("Hecks::Crew.Up", run: { value: "crew-4" }, checkout: { value: tapes })
    end
    expect(HecksCrewWorld.record(@hecks, "crew-4")).to include(status: "refused", last: /cannot read/)
  end

  it "refuses the crew when a role has no tape" do
    FileUtils.rm(File.join(tapes, "coder.jsonl"))
    expect(HecksCrewWorld.up(@hecks, "crew-2", tapes)).to include(status: "refused", last: /no tape in .* for coder/)
  end

  it "refuses the crew when the supervisor is not built" do
    adapter = Hecks::Adapters::CrewHarness.new(settings: { binary: File.join(tapes, "hecks-harness") })
    expect { adapter.bring_up(checkout: HecksCrewWorld::CHECKOUT, tapes: tapes) }
      .to raise_error(Hecks::Adapters::CrewHarness::NotBroughtUp, /not built/)
  end
end
