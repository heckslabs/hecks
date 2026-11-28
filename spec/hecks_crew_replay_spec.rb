# frozen_string_literal: true

require "spec_helper"
require "fileutils"
require "tmpdir"
require "hecks/hecks/adapters/crew_harness"
require_relative "support/hecks_harness_binary"
require_relative "support/hecks_crew_world"

# A crew run's journal replays through the harness against the pipeline: `Crew.up! journal=`
# writes the run's journal, and `Crew.replay! journal=` brings the checkout's crew up on tapes made
# from it and holds every act of the replay to the journal's. The run here is the fixture crew on
# the crew member's tape (see spec/hecks_crew_spec.rb), so no model runs. A checkout whose role
# file changed since the run briefs that role otherwise, and the replay names it.
module HecksCrewReplayWorld
  module_function

  # Replays a journal through the command, as the Maintainer, in a booted Hecks.
  #
  # @return [Hash] the Crew record as the ledger holds it, each value object as its value
  def replay(hecks, run, journal, checkout: HecksCrewWorld::CHECKOUT)
    Hecks::Runtime::Caller.as(role: "Maintainer") do
      hecks.dispatch_flat("Hecks::Crew.Replay", run: { value: run }, journal: { value: journal },
                                                checkout: { value: checkout })
    end
    HecksCrewWorld.record(hecks, run)
  end

  # Brings the fixture crew up for one turn of every session, its journal written to `journal`.
  def journaled(hecks, run, journal)
    tapes = HecksCrewWorld.tapes(HecksCrewWorld.crew)
    Hecks::Runtime::Caller.as(role: "Maintainer") do
      hecks.dispatch_flat("Hecks::Crew.Up", run: { value: run }, checkout: { value: HecksCrewWorld::CHECKOUT },
                                            tapes: { value: tapes }, turns: { value: 1 }, journal: { value: journal })
    end
    HecksCrewWorld.record(hecks, run)
  ensure
    FileUtils.rm_rf(tapes)
  end

  # A copy of the fixture checkout whose coder is briefed to do something else.
  def changed_checkout(dir)
    FileUtils.cp_r(File.join(HecksCrewWorld::CHECKOUT, "."), dir)
    coder = File.join(dir, ".claude/agents/coder.md")
    File.write(coder, File.read(coder).sub("run the specs it touches", "skip the specs"))
    dir
  end
end

RSpec.describe "The crew's journal replays through the harness against the pipeline", :io do
  include_context "with the hecks-harness binary"

  before(:all) do
    @hecks = boot_hecks_in_memory
    @scratch = Dir.mktmpdir("crew-journal")
    @journal = File.join(@scratch, "journal")
    @up = HecksCrewReplayWorld.journaled(@hecks, "journaled-1", @journal)
  end

  after(:all) { FileUtils.rm_rf(@scratch) }

  it "writes the run's journal, one recording a session" do
    expect([@up[:status], Dir.children(@journal).sort]).to eq(["ended", HecksCrewWorld.crew.map { |role| "#{role}.jsonl" }])
  end

  it "ends a replay that did every act the journal has, naming how many" do
    expect(HecksCrewReplayWorld.replay(@hecks, "replay-1", @journal))
      .to include(status: "ended", last: "replayed 20 acts of 4 sessions, each as the journal has it")
  end

  it "refuses the replay against a checkout whose role file changed, naming the role and its act" do
    checkout = HecksCrewReplayWorld.changed_checkout(File.join(@scratch, "changed"))
    named = include("the replay did otherwise: coder at act 1: the journal has ", "run the specs it touches",
                    "skip the specs").and(satisfy { |last| !last.include?("reviewer at") })
    expect(HecksCrewReplayWorld.replay(@hecks, "replay-2", @journal, checkout: checkout))
      .to include(status: "refused", last: named)
  end

  it "refuses the replay of a journal with no recording for one of the crew" do
    partial = File.join(@scratch, "partial")
    FileUtils.cp_r(@journal, partial)
    FileUtils.rm(File.join(partial, "coder.jsonl"))
    expect(HecksCrewReplayWorld.replay(@hecks, "replay-3", partial))
      .to include(status: "refused", last: end_with("the journal at #{partial} has no recording for coder"))
  end

  it "refuses the replay of a journal that is not there" do
    missing = File.join(@scratch, "missing")
    expect(HecksCrewReplayWorld.replay(@hecks, "replay-4", missing))
      .to include(status: "refused", last: end_with("no journal at #{missing}"))
  end
end
