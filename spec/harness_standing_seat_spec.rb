require "spec_helper"
require "hecks/harness/run"
require_relative "support/hecks_harness_binary"

# A standing seat keeps its session's name across the sessions that fill it. When the seat's
# session stopped, its next run reopens it, and the new child is told its brief and then the
# handover the last session left: what that session said at the end of its last turn that said
# something. Each child is played from its tape in rust/harness/tests/tapes, and a tape checks
# what its child is told.
module HarnessStandingSeatWorld
  TAPES = File.join(HecksHarnessBinary::DIR, "tests/tapes")
  SEAT = "scrum-master".freeze
  BRIEF = "You are the scrum master.".freeze
  LEFT = "Holding the seat: coder-1 waits on the lead about the freeze, and nothing else is open.".freeze
  TOOK = "Took up the seat: coder-1 still waits on the lead about the freeze.".freeze

  # What the ledger held at each point the spec reads, all before the run is closed.
  Seen = Struct.new(:left, :taken_up, :last_run, :next_run, :events)

  # Each open of a session plays the next of its tapes, so a reopened seat plays a tape of its own.
  #
  # @param tapes [Hash{String => Array<String>}] a session's name to the tapes its opens play
  # @return [Proc] the launch for a session name
  def self.launch(tapes)
    queued = tapes.transform_values(&:dup)
    ->(name) { { program: Hecks::Harness::Supervisor::BINARY, args: ["replay", File.join(TAPES, "#{queued[name].shift}.jsonl")] } }
  end

  # The seat's first run leaves its handover and is stopped; the next run takes the seat up.
  #
  # @return [Seen]
  def self.handed_over
    @handed_over ||= begin
      run = Hecks::Harness::Run.new(launch: launch(SEAT => %w[seat_first seat_successor]))
      run.start("seat-1", SEAT, BRIEF)
      run.pump { |tells| turns(tells) == 1 }
      stop(run)
      left = record(run, "Session", SEAT)
      run.take_seat("seat-2", SEAT, BRIEF)
      run.pump { |tells| turns(tells) == 2 }
      seen(run, left)
    end
  end

  # A seat whose first session said nothing, so its next session is told its brief alone.
  #
  # @return [Seen]
  def self.silent
    @silent ||= begin
      run = Hecks::Harness::Run.new(launch: launch(SEAT => %w[seat_silent seat_silent]))
      run.start("seat-1", SEAT, BRIEF)
      run.pump { |tells| turns(tells) == 1 }
      stop(run)
      left = record(run, "Session", SEAT)
      run.take_seat("seat-2", SEAT, BRIEF)
      run.pump { |tells| turns(tells) == 2 }
      seen(run, left)
    end
  end

  # A seat whose session still runs: the next run is refused the reopening, and waits.
  #
  # @return [Seen]
  def self.taken
    @taken ||= begin
      run = Hecks::Harness::Run.new(launch: launch(SEAT => %w[seat_first]))
      run.start("seat-1", SEAT, BRIEF)
      run.pump { |tells| turns(tells) == 1 }
      run.take_seat("seat-2", SEAT, BRIEF)
      seen(run, nil)
    end
  end

  NAMES = %w[SessionRunning HandoverLeft SessionStopped SessionReopenRequested].freeze

  # @return [Seen] the seat as the ledger holds it now, read before the run is closed
  def self.seen(run, left)
    Seen.new(left, record(run, "Session", SEAT), record(run, "AgentRun", "seat-1"), record(run, "AgentRun", "seat-2"),
             events(run, SEAT, NAMES)).tap { run.close }
  end

  def self.stop(run)
    run.stop(SEAT)
    run.pump { |tells| tells.any? { |tell| tell["tell"] == "stopped" } }
  end

  # @return [Integer] the turns the seat's sessions have ended
  def self.turns(tells) = tells.count { |tell| tell["tell"] == "turn_ended" && tell["session"] == SEAT }

  # @return [Hash] a record as the ledger holds it now, each value object as its value
  def self.record(run, aggregate, key)
    registry = run.runtime.registry
    found = registry.repository("Harness", registry.bluebook("Harness").aggregate(aggregate)).find(key)
    Hecks::Runtime::Value.materialize(found.state).transform_values { |value| value.is_a?(Hash) ? value[:value] : value }
  end

  # @return [Array<String>] the names of a record's events, in order, from those named
  def self.events(run, key, names)
    run.runtime.events.select { |event| event.id == key && names.include?(event.name) }.map(&:name)
  end
end

RSpec.describe "A standing seat starts from a handover record", :io do
  include_context "with the hecks-harness binary"

  let(:seen) { HarnessStandingSeatWorld.handed_over }

  it "keeps what the seat's session said at the end of its last turn as the handover it leaves" do
    expect(seen.left).to include(status: "stopped", handover: HarnessStandingSeatWorld::LEFT)
  end

  it "reopens the stopped seat under its own name, on the next run's brief, as the Claude session its new child became" do
    expect(seen.taken_up).to include(name: "scrum-master", brief: "You are the scrum master.", claude: "replay-seat-successor")
  end

  it "tells the seat's next session its brief and then the handover, and the next session takes up from it" do
    expect(seen.taken_up).to include(status: "running", handover: HarnessStandingSeatWorld::TOOK)
  end

  it "starts the seat's next run in the reopened session, and reports from it" do
    expect(seen.next_run).to include(status: "started", session: "scrum-master", report: HarnessStandingSeatWorld::TOOK)
  end

  it "finishes the seat's last run when its session stopped, and leaves it finished when the seat is reopened" do
    expect(seen.last_run).to include(status: "finished", condition: "done", code: "0")
  end

  it "records the seat's session left, stopped, reopened and running again, in that order" do
    expect(seen.events).to eq(%w[SessionRunning HandoverLeft SessionStopped SessionReopenRequested SessionRunning HandoverLeft])
  end

  it "leaves no handover from a session whose turns said nothing, so its seat's next run starts from its brief alone" do
    silent = HarnessStandingSeatWorld.silent
    expect([silent.left[:handover], silent.next_run[:status]]).to eq([nil, "started"])
  end

  it "refuses to reopen a seat whose session still runs, and leaves the next run waiting" do
    taken = HarnessStandingSeatWorld.taken
    expect([taken.taken_up[:status], taken.next_run[:status]]).to eq(%w[running requested])
  end
end
