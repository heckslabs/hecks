require "spec_helper"
require "hecks/harness/run"
require_relative "support/hecks_harness_binary"

# The resident staff engineer runs as a Harness session, briefed from its role file, beside the
# sessions that ask it and, when she is open, Miette. Each child is played from its tape in
# rust/harness/tests/tapes. A coder's question goes to the staff engineer, which asks Miette and
# relays her answer, about the coder's message; the Harness's policies record the relay in the
# StaffEngineer bluebook. When Miette is not open, the delivery to her is refused, the staff
# engineer is told, the relay is declined, and nothing reaches the asker as her words.
module HarnessStaffEngineerWorld
  TAPES = File.join(HecksHarnessBinary::DIR, "tests/tapes")

  # One run: the sessions it opens (a role, or a name and its brief), the tape each plays, and
  # the turns each tape plays, so the run is over once every session has ended them all.
  Scene = Struct.new(:roles, :briefs, :tapes, :turns) do
    # @return [Hecks::Harness::Run] the run, played to its end and closed, its ledger kept
    def play
      Hecks::Harness::Run.new(launch: Hecks::Harness::Launch.replay(TAPES, tapes: tapes)).tap do |run|
        roles.each { |role| run.open_role(role) }
        briefs.each { |name, brief| run.open(name, brief) }
        run.pump { |tells| over?(tells) }
        run.close
      end
    end

    # @return [Boolean] whether every session has ended all its turns
    def over?(tells) = turns.all? { |name, count| HarnessStaffEngineerWorld.ended(tells, name) == count }
  end

  RELAYED = Scene.new(
    %w[staff-engineer],
    { "miette" => "You are Miette. Answer the staff engineer in your own words.",
      "coder"  => "You are the coder. Ask the staff engineer when a relay rule is unclear." },
    { "staff-engineer" => "staff_engineer", "coder" => "coder_asks" },
    { "staff-engineer" => 3, "miette" => 2, "coder" => 2 }
  ).freeze

  UNREACHED = Scene.new(
    %w[staff-engineer],
    { "reviewer" => "You are the reviewer. Ask the staff engineer when a rule is unclear." },
    { "staff-engineer" => "staff_engineer_alone", "reviewer" => "reviewer_asks" },
    { "staff-engineer" => 3, "reviewer" => 2 }
  ).freeze

  # @return [Integer] the turns a session has ended
  def self.ended(tells, name) = tells.count { |tell| tell["tell"] == "turn_ended" && tell["session"] == name }

  # @return [Hecks::Harness::Run] the scene's run, played once for every example to read
  def self.played(scene) = (@played ||= {})[scene] ||= scene.play
end

RSpec.describe "The staff engineer as a Harness session", :io do
  include_context "with the hecks-harness binary"

  # @return [Array<Hash>] the payloads of the run's events with this name
  def payloads(name) = run.runtime.events.select { |event| event.name == name }.map(&:payload)

  # @return [Array<Object>] one field's value in each of those payloads, nil where it is absent
  def values(name, field) = payloads(name).map { |payload| payload[field] && payload[field][:value] }

  # @return [Hash] the posted message with this key
  def posted(key) = payloads("MessagePosted").find { |payload| payload[:key][:value] == key }

  # @return [Array<Hash>] the reactions a policy ran
  def reactions(policy) = run.runtime.registry.reaction_log.select { |reaction| reaction[:policy] == policy }

  describe "when Miette answers" do
    let(:run) { HarnessStaffEngineerWorld.played(HarnessStaffEngineerWorld::RELAYED) }

    it "briefs the staff engineer from its role file" do
      brief = payloads("SessionOpenRequested").find { |payload| payload[:name][:value] == "staff-engineer" }[:brief][:value]
      expect(brief).to start_with("You run as a harness session.").and include("You are the staff engineer role:")
    end

    it "carries the coder's question to Miette and her answer back, each about the coder's message" do
      expect(values("MessagePosted", :sender).zip(values("MessagePosted", :addressee), values("MessagePosted", :about)))
        .to eq([%w[coder staff-engineer] + [nil], %w[staff-engineer miette coder-1],
                %w[miette staff-engineer coder-1], %w[staff-engineer coder coder-1]])
    end

    it "delivers every message" do
      expect(payloads("MessageDelivered").map { |payload| payload[:message] })
        .to eq(%w[coder-1 staff-engineer-1 miette-1 staff-engineer-2])
    end

    it "hands the coder her words unchanged" do
      expect(posted("staff-engineer-2")[:text][:value]).to eq(posted("miette-1")[:text][:value])
    end

    it "records the relay asked, received and answered, in her words and labelled as hers" do
      expect([values("Asked", :relay), values("Asked", :run), values("Received", :received),
              values("Answered", :words), values("Answered", :author)])
        .to eq([%w[coder-1], %w[coder], [posted("miette-1")[:text][:value]],
                [posted("miette-1")[:text][:value]], %w[miette]])
    end

    it "declines nothing" do
      expect(payloads("Declined")).to be_empty
    end
  end

  describe "when Miette is not reached" do
    let(:run) { HarnessStaffEngineerWorld.played(HarnessStaffEngineerWorld::UNREACHED) }

    it "refuses the delivery to her and tells the staff engineer" do
      expect([values("DeliveryRefused", :key), run.tells.count { |tell| tell["tell"] == "noticed" }])
        .to eq([%w[staff-engineer-1], 1])
    end

    it "declines the relay for the reviewer's message" do
      expect([values("Asked", :relay), reactions("DeclineWhenMietteIsNotReached").map { |reaction| reaction[:delivered] }])
        .to eq([%w[reviewer-1], [true]])
    end

    it "tells the reviewer she was not reached, about the reviewer's message" do
      expect(posted("staff-engineer-2").slice(:addressee, :about).transform_values { |value| value[:value] })
        .to eq(addressee: "reviewer", about: "reviewer-1")
    end

    it "records nothing as her words" do
      expect([payloads("Answered"), reactions("ForwardMiettesAnswer").map { |reaction| reaction[:delivered] }])
        .to eq([[], [false]])
    end
  end
end
