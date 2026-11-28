require "spec_helper"
require "hecks/harness/run"
require_relative "support/hecks_harness_binary"

# An urgent message cuts into its addressee's turn. A worker is mid-turn when a peer leaves it an
# ordinary note and the lead sends it an urgent one: the supervisor interrupts the worker's turn,
# the worker takes the lead's message next and the peer's after it. Each child is played from its
# tape in rust/harness/tests/tapes, on a Memory ledger thrown away with the run.
module HarnessUrgentWorld
  TAPES = File.join(HecksHarnessBinary::DIR, "tests/tapes")
  # Each session's brief, which its tape checks.
  BRIEFS = { "worker" => "You are the worker. Carry the change through.",
             "peer"   => "You are the peer. Leave the worker a note.",
             "lead"   => "You are the lead. Main just moved." }.freeze
  # The tape each session plays.
  PLAYS = BRIEFS.keys.to_h { |name| [name, "urgent_#{name}"] }.freeze
  # The turns each tape plays: the run is over once every session has ended them all.
  TURNS = { "worker" => 3, "peer" => 1, "lead" => 1 }.freeze

  # Runs the three sessions once, for every example to read: the run is closed and its ledger kept.
  #
  # @return [Hecks::Harness::Run]
  def self.run
    @run ||= Hecks::Harness::Run.new(launch: Hecks::Harness::Launch.replay(TAPES, tapes: PLAYS)).tap do |run|
      BRIEFS.each { |name, brief| run.open(name, brief) }
      run.pump { |tells| TURNS.all? { |name, turns| ended(tells, name) == turns } }
      run.close
    end
  end

  # @return [Integer] the turns a session has ended
  def self.ended(tells, name) = tells.count { |tell| tell["tell"] == "turn_ended" && tell["session"] == name }

  # @return [Array<Hash>] the payloads of the run's events with this name
  def payloads(name) = HarnessUrgentWorld.run.runtime.events.select { |event| event.name == name }.map(&:payload)

  # @return [Array<String>] the kinds of the tells about one message, and of the worker's turn
  #   ends, in order
  def told(message)
    HarnessUrgentWorld.run.tells.select { |tell| tell["message"] == message || worker_turn?(tell) }.map { |tell| tell["tell"] }
  end

  def worker_turn?(tell) = tell["tell"] == "turn_ended" && tell["session"] == "worker"

  # @return [Hash] the message as the ledger holds it now, each value object as its value
  def message(key)
    registry = HarnessUrgentWorld.run.runtime.registry
    record = registry.repository("Harness", registry.bluebook("Harness").aggregate("Message")).find(key)
    Hecks::Runtime::Value.materialize(record.state).transform_values { |value| value.is_a?(Hash) ? value[:value] : value }
  end
end

RSpec.describe "Harness urgent messages", :io do
  include_context "with the hecks-harness binary"
  include HarnessUrgentWorld

  it "posts the lead's message urgent and the peer's normal" do
    expect(payloads("MessagePosted").to_h { |payload| [payload[:key][:value], payload[:urgency][:value]] })
      .to eq("peer-1" => "normal", "lead-1" => "urgent")
  end

  it "interrupts the worker's turn for the urgent message, and delivers it when the cut turn ends" do
    expect(told("lead-1").drop_while { |kind| kind != "sent" }.take(5)).to eq(%w[sent queued interrupted turn_ended delivered])
  end

  it "records the cut turn, by the message that cut it, as an error" do
    cut = payloads("TurnInterrupted").map { |payload| payload[:cutter][:value] }
    worker = payloads("TurnEnded").select { |payload| payload[:session] == "worker" }
    outcomes = worker.map { |payload| payload[:outcome][:value] }
    expect([cut, outcomes]).to eq([["lead-1"], %w[error success success]])
  end

  it "delivers the urgent message ahead of the ordinary one sent before it" do
    expect(payloads("MessageDelivered").map { |payload| payload[:message] }).to eq(%w[lead-1 peer-1])
  end

  it "keeps the message's urgency in the ledger" do
    expect([message("lead-1")[:urgency], message("peer-1")[:urgency]]).to eq(%w[urgent normal])
  end
end
