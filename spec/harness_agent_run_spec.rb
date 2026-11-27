require "spec_helper"
require "hecks/harness/run"
require_relative "support/hecks_harness_binary"

# A run of one role, started in a Harness session, is finished only when that session ended. Each
# child is played from its tape in rust/harness/tests/tapes. The coder's first turn ends with its
# closing words, "ready for review", and the reviewer then answers it twice: each turn's end is a
# report and the run stays started, until the coder's session is stopped and its child exits. A
# child that exits with an error ends its run failed, and a session never opened refuses its run.
module HarnessAgentRunWorld
  TAPES = File.join(HecksHarnessBinary::DIR, "tests/tapes")
  CODER = "You are the coder. Your change to the ledger is up for review.".freeze
  REVIEWER = "You are the reviewer. Review the coder's change to the ledger.".freeze

  # The run as the ledger held it at each point the spec reads.
  Seen = Struct.new(:run, :reported, :answered, :stopped)

  # The coder reports, is answered twice, and is stopped; the ledger is read at each step.
  #
  # @return [Seen]
  def self.worked
    @worked ||= begin
      run = started
      reported = read_after(run, { "coder" => 1 })
      answered = read_after(run, { "coder" => 3, "reviewer" => 2 })
      run.stop("coder")
      run.pump { |tells| tells.any? { |tell| tell["tell"] == "stopped" && tell["session"] == "coder" } }
      Seen.new(run, reported, answered, agent_run(run, "work-1")).tap { run.close }
    end
  end

  # @return [Hecks::Harness::Run] the coder's and the reviewer's runs, started
  def self.started
    Hecks::Harness::Run.new(launch: Hecks::Harness::Launch.replay(TAPES)).tap do |run|
      run.start("work-1", "coder", CODER)
      run.start("review-1", "reviewer", REVIEWER)
    end
  end

  # @return [Hash] the coder's run, once each session has ended that many turns
  def self.read_after(run, turns)
    run.pump { |tells| turns.all? { |name, count| ended(tells, name) == count } }
    agent_run(run, "work-1")
  end

  # A coder whose child cannot read its tape, so the replay exits with code 2.
  #
  # @return [Hecks::Harness::Run]
  def self.crashed
    launch = Hecks::Harness::Launch.replay(TAPES, tapes: { "coder" => "no_such_tape" })
    @crashed ||= Hecks::Harness::Run.new(launch: launch).tap do |run|
      run.start("work-2", "coder", CODER)
      run.pump { |tells| tells.any? { |tell| tell["tell"] == "stopped" } }
      run.close
    end
  end

  # A coder whose child's program does not exist, so its session is never opened.
  #
  # @return [Hecks::Harness::Run]
  def self.unopened
    @unopened ||= Hecks::Harness::Run.new(launch: ->(_name) { { program: "/nonexistent/claude" } }).tap do |run|
      run.start("work-3", "coder", CODER)
      run.close
    end
  end

  # @return [Integer] the turns a session has ended
  def self.ended(tells, name) = tells.count { |tell| tell["tell"] == "turn_ended" && tell["session"] == name }

  # @return [Hash] the run as the ledger holds it now, each value object as its value
  def self.agent_run(run, key)
    registry = run.runtime.registry
    record = registry.repository("Harness", registry.bluebook("Harness").aggregate("AgentRun")).find(key)
    Hecks::Runtime::Value.materialize(record.state).transform_values { |value| value.is_a?(Hash) ? value[:value] : value }
  end

  # @return [Array<String>] the names of a run's events, in order
  def self.events(run, key) = run.runtime.events.select { |event| event.name.start_with?("Run") && event.id == key }.map(&:name)
end

RSpec.describe "A harness run is finished only when its session ended", :io do
  include_context "with the hecks-harness binary"

  let(:seen) { HarnessAgentRunWorld.worked }

  it "starts the run once its session runs" do
    expect(seen.reported).to include(status: "started", session: "coder")
  end

  it "keeps the run started when a turn ends with the role's closing words" do
    expect(seen.reported).to include(status: "started", report: "The change is ready for review.", condition: "")
  end

  it "keeps the run started while the session is answered and works on, holding its last report" do
    expect(seen.answered).to include(status: "started", report: "Approved; nothing left to do.")
  end

  it "records each turn's end as a report, and finishes the run once" do
    expect(HarnessAgentRunWorld.events(seen.run, "work-1"))
      .to eq(%w[RunRequested RunStarted RunReported RunReported RunReported RunFinished])
  end

  it "finishes the run done when its session is stopped and its child exits cleanly" do
    expect(seen.stopped).to include(status: "finished", condition: "done", code: "0", report: "Approved; nothing left to do.")
  end

  it "finishes the reviewer's run too, when closing the run stops its session" do
    expect(HarnessAgentRunWorld.agent_run(seen.run, "review-1"))
      .to include(status: "finished", condition: "done", report: "Approved the ledger change.")
  end

  it "finishes the run failed when its child exits with an error, keeping the exit code" do
    expect(HarnessAgentRunWorld.agent_run(HarnessAgentRunWorld.crashed, "work-2"))
      .to include(status: "finished", condition: "failed", code: "2")
  end

  it "refuses the run when its session is never opened" do
    expect(HarnessAgentRunWorld.agent_run(HarnessAgentRunWorld.unopened, "work-3")).to include(status: "refused", condition: "")
  end
end
