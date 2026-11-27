require "spec_helper"
require "json"
require "open3"
require "hecks/harness/run"
require_relative "support/hecks_harness_binary"

# A reviewer and a coder run as Harness sessions, each child played from its tape in
# rust/harness/tests/tapes, on a Memory ledger thrown away with the run. The reviewer asks the
# coder a question while the coder is still mid-turn, the coder answers, and the reviewer approves:
# every message is posted in the bluebook, delivered by its policy, and timed against the baseline.
module HarnessExchangeWorld
  TAPES = File.join(HecksHarnessBinary::DIR, "tests/tapes")
  BRIEFS = { "reviewer" => "You are the reviewer. Review the coder's change to the ledger.",
             "coder"    => "You are the coder. Your change to the ledger is up for review." }.freeze
  # The turns each tape plays: the exchange is over once both have ended them all.
  TURNS = { "reviewer" => 2, "coder" => 3 }.freeze

  # Runs the exchange once, for every example to read: the run is closed and its ledger kept.
  #
  # @return [Hecks::Harness::Run]
  def self.exchanged
    @exchanged ||= Hecks::Harness::Run.new(launch: Hecks::Harness::Launch.replay(TAPES)).tap do |run|
      BRIEFS.each { |name, brief| run.open(name, brief) }
      run.pump { |tells| TURNS.all? { |name, turns| ended(tells, name) == turns } }
      run.close
    end
  end

  # @return [Integer] the turns a session has ended
  def self.ended(tells, name) = tells.count { |tell| tell["tell"] == "turn_ended" && tell["session"] == name }

  # @return [Hash] what `hecks-harness measure` reads of the run's tells
  def self.measured
    @measured ||= Dir.mktmpdir("hecks-harness") do |dir|
      path = File.join(dir, "tells.jsonl")
      File.write(path, exchanged.tells.map { |tell| JSON.generate(tell) }.join("\n"))
      JSON.parse(Open3.capture2(Hecks::Harness::Supervisor::BINARY, "measure", path).first)
    end
  end

  # @return [Hecks::Harness::Run] the one run
  def exchanged = HarnessExchangeWorld.exchanged

  # @return [Hash] the run measured against the baseline
  def measured = HarnessExchangeWorld.measured

  # @return [Array<Hash>] the payloads of the run's events with this name
  def payloads(name) = exchanged.runtime.events.select { |event| event.name == name }.map(&:payload)

  # @return [Array<Object>] one field's value in each of those payloads
  def values(name, field) = payloads(name).map { |payload| payload[field][:value] }

  # @return [Array<String>] the kinds of the tells about one message or one session, in order
  def told(message, session)
    exchanged.tells.select { |tell| tell["message"] == message || tell["session"] == session }.map { |tell| tell["tell"] }
  end
end

RSpec.describe "Harness sessions exchanging messages", :io do
  include_context "with the hecks-harness binary"
  include HarnessExchangeWorld

  it "posts each message the sessions send, sender to addressee, in order" do
    expect(values("MessagePosted", :sender).zip(values("MessagePosted", :addressee)))
      .to eq([%w[reviewer coder], %w[coder reviewer], %w[reviewer coder]])
  end

  it "delivers every posted message by policy" do
    expect(payloads("MessageDelivered").map { |payload| payload[:message] }).to eq(%w[reviewer-1 coder-1 reviewer-2])
  end

  it "holds the reviewer's question until the coder's turn ends" do
    expect(told("reviewer-1", "coder").drop_while { |kind| kind != "queued" }.take(3)).to eq(%w[queued turn_ended delivered])
  end

  it "withholds the shell from the reviewer and records it" do
    expect(values("ToolWithheld", :tool)).to eq(["Bash"])
  end

  it "records the Claude session each child reported" do
    expect(values("SessionStarted", :claude)).to contain_exactly("replay-reviewer", "replay-coder")
  end

  it "stops both sessions cleanly" do
    expect(values("SessionStopped", :code)).to eq(%w[0 0])
  end

  it "delivers within the baseline of 322 s at p90, and answers within 673 s" do
    expect(measured).to include("within_baseline" => true, "undelivered" => 0)
  end

  it "times each delivery in the ledger as the supervisor measured it" do
    sent = values("MessagePosted", :key).zip(values("MessagePosted", :sent_at)).to_h
    waits = payloads("MessageDelivered").map { |payload| payload[:delivered_at][:value] - sent.fetch(payload[:message]) }
    expect(waits.max).to eq(measured.dig("delivery", "max_ms"))
  end
end
