require "spec_helper"
require "hecks/harness/run"
require_relative "support/hecks_harness_binary"

# The scrum master runs as a Harness session, briefed from its role file, beside a coder and the
# orchestrator. Each child is played from its tape in rust/harness/tests/tapes. A coder's question
# reaches the scrum master first, sent to it or routed from the orchestrator. The Harness's
# policies hold it there until the scrum master answers the coder (settled), sends the lead what it
# found (handed on, the question before the findings), cannot be reached, or lets fifteen minutes
# pass on the supervisor's clock (handed on by a tick).
module HarnessScrumMasterWorld
  TAPES = File.join(HecksHarnessBinary::DIR, "tests/tapes")

  # A tick the spec records past the question's window, beside the supervisor's own.
  WINDOW_MS = 900_000

  # One run: the sessions it opens (a role, or a name and its brief), the tape each plays, the
  # turns each tape plays, and, for a question left alone, the turns to wait for before the clock
  # is moved past its window.
  Scene = Struct.new(:roles, :briefs, :tapes, :turns, :left) do
    # @return [Hecks::Harness::Run] the run, played to its end and closed, its ledger kept
    def play
      launch = Hecks::Harness::Launch.replay(TAPES, tapes: tapes)
      Hecks::Harness::Run.new(launch: launch, tick_ms: 50).tap do |run|
        open_all(run)
        pass_the_window(run) if left
        run.pump { |tells| reached?(tells, turns) }
        run.close
      end
    end

    # Opens each role on its role file and each other session on its brief.
    def open_all(run)
      roles.each { |role| run.open_role(role) }
      briefs.each { |name, brief| run.open(name, brief) }
    end

    # Once the question is left, records a tick just inside its window and one at its end.
    def pass_the_window(run)
      run.pump { |tells| reached?(tells, left) }
      sent = run.tells.find { |tell| tell["tell"] == "sent" && tell["message"] == "coder-1" }.fetch("at_ms").to_i
      [WINDOW_MS - 1, WINDOW_MS].each { |wait| Hecks::Harness::Tells.record(run.runtime, { "tell" => "tick", "at_ms" => sent + wait }) }
    end

    # @return [Boolean] whether every named session has ended that many turns
    def reached?(tells, counts) = counts.all? { |name, count| HarnessScrumMasterWorld.ended(tells, name) == count }
  end

  CODER = "You are the coder. Ask when you are stuck.".freeze
  LEAD  = "You are the orchestrator. Answer what reaches you.".freeze

  SETTLED = Scene.new(
    %w[scrum-master], { "coder" => CODER, "orchestrator" => LEAD },
    { "scrum-master" => "scrum_master_settles", "coder" => "coder_routes", "orchestrator" => "orchestrator_idle" },
    { "scrum-master" => 2, "coder" => 2, "orchestrator" => 1 }, nil
  ).freeze

  NOTED = Scene.new(
    %w[scrum-master], { "coder" => CODER, "orchestrator" => LEAD },
    { "scrum-master" => "scrum_master_notes", "coder" => "coder_stuck", "orchestrator" => "orchestrator_noted" },
    { "scrum-master" => 2, "coder" => 2, "orchestrator" => 3 }, nil
  ).freeze

  LEFT = Scene.new(
    %w[scrum-master], { "coder" => CODER, "orchestrator" => LEAD },
    { "scrum-master" => "scrum_master_leaves", "coder" => "coder_stuck", "orchestrator" => "orchestrator_answers" },
    { "scrum-master" => 2, "coder" => 2, "orchestrator" => 2 },
    { "scrum-master" => 2, "coder" => 1, "orchestrator" => 1 }
  ).freeze

  UNREACHED = Scene.new(
    [], { "coder" => CODER, "orchestrator" => LEAD },
    { "coder" => "coder_unreached", "orchestrator" => "orchestrator_answers" },
    { "coder" => 3, "orchestrator" => 2 }, nil
  ).freeze

  # @return [Integer] the turns a session has ended
  def self.ended(tells, name) = tells.count { |tell| tell["tell"] == "turn_ended" && tell["session"] == name }

  # @return [Hecks::Harness::Run] the scene's run, played once for every example to read
  def self.played(scene) = (@played ||= {})[scene] ||= scene.play
end

RSpec.describe "The scrum master as a Harness session", :io do
  include_context "with the hecks-harness binary"

  # @return [Array<Hash>] the payloads of the run's events with this name
  def payloads(name) = run.runtime.events.select { |event| event.name == name }.map(&:payload)

  # @return [Array<Array(String, String)>] each delivery written: the message and its reader
  def deliveries = run.tells.select { |tell| tell["tell"] == "delivered" }.map { |tell| tell.values_at("message", "session") }

  # @return [Array<String>] the message each event with this name was emitted for
  def emitted_for(name) = run.runtime.events.select { |event| event.name == name }.map(&:id)

  # @return [Hash] the message as the ledger holds it now, each value object as its value
  def message(key)
    registry = run.runtime.registry
    record = registry.repository("Harness", registry.bluebook("Harness").aggregate("Message")).find(key)
    Hecks::Runtime::Value.materialize(record.state).transform_values { |value| value.is_a?(Hash) ? value[:value] : value }
  end

  # @return [Array<Boolean>] whether each of a policy's reactions was delivered
  def reactions(policy)
    run.runtime.registry.reaction_log.select { |reaction| reaction[:policy] == policy }.map { |reaction| reaction[:delivered] }
  end

  describe "when the code settles a question the coder put to the orchestrator" do
    let(:run) { HarnessScrumMasterWorld.played(HarnessScrumMasterWorld::SETTLED) }

    it "briefs the scrum master from its role file, with where its findings go" do
      brief = payloads("SessionOpenRequested").find { |payload| payload[:name][:value] == "scrum-master" }[:brief][:value]
      expect(brief).to start_with("You run as a harness session.").and include("send what you found to the orchestrator")
        .and include("You are the scrum master")
    end

    it "routes the question to the scrum master, so the orchestrator never hears it" do
      expect([emitted_for("MessageRouted"), deliveries])
        .to eq([%w[coder-1], [%w[coder-1 scrum-master], %w[scrum-master-1 coder]]])
    end

    it "settles the question by the scrum master's answer to the coder, about it" do
      expect([message("coder-1").values_at(:addressee, :hold, :status), message("scrum-master-1")[:about]])
        .to eq([%w[scrum-master settled delivered], "coder-1"])
    end

    it "does not deliver the routed question to the orchestrator as well" do
      expect(reactions("DeliverEachMessage").size).to eq(1)
    end
  end

  describe "when the scrum master sends the lead what it found" do
    let(:run) { HarnessScrumMasterWorld.played(HarnessScrumMasterWorld::NOTED) }

    it "hands the question on to the orchestrator before the findings" do
      expect(deliveries).to eq([%w[coder-1 scrum-master], %w[coder-1 orchestrator], %w[scrum-master-1 orchestrator],
                                %w[orchestrator-1 coder]])
    end

    it "records the findings on the question, handed on to the orchestrator" do
      expect(message("coder-1").values_at(:addressee, :hold, :findings, :status))
        .to eq(%w[orchestrator handed-on scrum-master-1 delivered])
    end
  end

  describe "when the scrum master leaves the question" do
    let(:run) { HarnessScrumMasterWorld.played(HarnessScrumMasterWorld::LEFT) }

    it "records the supervisor's own ticks" do
      expect(run.tells.count { |tell| tell["tell"] == "tick" }).to be_positive
    end

    it "holds the question inside its window and hands it on at its end" do
      handed = reactions("HandOnWhatTheScrumMasterLeft").count(true)
      expect([emitted_for("QuestionHandedOn"), handed, message("coder-1")[:findings]]).to eq([%w[coder-1], 1, nil])
    end

    it "brings the orchestrator's answer to the coder" do
      expect(deliveries.last(2)).to eq([%w[coder-1 orchestrator], %w[orchestrator-1 coder]])
    end
  end

  describe "when no scrum master is open" do
    let(:run) { HarnessScrumMasterWorld.played(HarnessScrumMasterWorld::UNREACHED) }

    it "tells the coder, and hands the question on to the orchestrator at once" do
      expect([run.tells.count { |tell| tell["tell"] == "noticed" }, deliveries])
        .to eq([1, [%w[coder-1 orchestrator], %w[orchestrator-1 coder]]])
    end

    it "records the question handed on with no findings" do
      expect(message("coder-1").values_at(:addressee, :hold, :findings, :status))
        .to eq(["orchestrator", "handed-on", nil, "delivered"])
    end
  end
end
