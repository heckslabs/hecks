require "spec_helper"
require_relative "support/agents_message_helpers"

# A message its session never heard falls back to Claude messaging: once it has waited its window
# the holder's session is resumed with a line to read its inbox, once, and never while it works.
RSpec.describe "the Agents message unread fallback" do
  include AgentsMessageHelpers

  before { boot_messages }

  def role_sessions = @role_sessions ||= [{ "id" => "ab12", "name" => "orchestrator", "status" => "busy", "state" => "working" }]

  def recorded = @agents_runtime.events.map { |event| event.respond_to?(:name) ? event.name : event[:name] }.map(&:to_s)

  def fall_back(key, now) = rouser_standing { Hecks::Agents::Message.find(key).fall_back!(now: { value: now }) }

  def rouser_standing(&block)
    rouser = role_rouser
    Hecks::Runtime::AdapterLookup.standing_in(->(_port, _asked) { rouser }, &block)
  end

  def escalate(key, now) = rouser_standing { Hecks::Agents::Message.find(key).escalate!(now: { value: now }) }

  def go_idle = role_sessions.first.merge!("status" => "idle", "state" => "idle")

  it "resumes an idle holder once the unread message has waited its window", :aggregate_failures do
    send_message(to: "orchestrator")
    go_idle
    fall_back("m1", 1_400)
    expect(resumed.map(&:first)).to eq(["ab12"])
    expect(Hecks::Agents::Message.find("m1").fallen_back_at.value).to eq(1_400)
  end

  it "refuses to fall back inside the window" do
    send_message(to: "orchestrator")
    expect { fall_back("m1", 1_100) }.to raise_error(Hecks::Runtime::GivenNotMet, /waited/)
  end

  it "never stops a holder that is still working", :aggregate_failures do
    send_message(to: "orchestrator")
    fall_back("m1", 1_400)
    expect(resumed).to be_empty
    expect(Hecks::Agents::Message.find("m1").fallen_back_at&.value.to_i).to eq(0)
  end

  it "falls back once, so the second sweep finds nothing unread" do
    send_message(to: "orchestrator")
    go_idle
    fall_back("m1", 1_400)
    expect(Hecks::Agents::Message.unread.map { |row| row[:message].value }).to be_empty
  end

  it "does not list a message already read" do
    send_message(to: "orchestrator")
    Hecks::Agents::Message.find("m1").read!(reader: { value: "orchestrator" })
    expect(Hecks::Agents::Message.unread).to be_empty
  end

  it "measures an escalated question's window from its escalation" do
    send_message(to: "orchestrator", sender: "coder-a", kind: "question", asker: "coder")
    escalate("m1", 2_000)
    expect { fall_back("m1", 2_200) }.to raise_error(Hecks::Runtime::GivenNotMet, /waited/)
  end

  it "lists a freshly sent message as unread" do
    send_message(to: "orchestrator")
    expect(Hecks::Agents::Message.unread.map { |row| row[:message].value }).to eq(["m1"])
  end

  context "with a scrum master registered" do
    def recipients = { "scrum-master" => live_run, "orchestrator" => live_run }

    def role_sessions
      @role_sessions ||= %w[scrum-master orchestrator].map do |role|
        { "id" => "id-#{role}", "name" => role, "status" => "idle", "state" => "idle" }
      end
    end

    it "lets the lead's own window pass after the question already fell back with the scrum master" do
      send_message(to: "scrum-master", sender: "coder-a", kind: "question", asker: "coder")
      fall_back("m1", 1_400)
      escalate("m1", 2_000)
      fall_back("m1", 2_400)
      expect(resumed.map(&:first).last).to eq("id-orchestrator")
    end
  end

  context "with a role no session holds" do
    def recipients = { "owner" => live_run, "orchestrator" => live_run }

    it "records the fall back once, so the next sweep finds the message spent", :aggregate_failures do
      send_message(to: "owner")
      fall_back("m1", 1_400)
      expect(recorded).to include("FallBackFoundNoHolder")
      expect { fall_back("m1", 1_500) }.to raise_error(Hecks::Runtime::GivenNotMet, /already fell back|fallen back/)
    end

    it "leaves the message out of the unread listing once spent" do
      send_message(to: "owner")
      fall_back("m1", 1_400)
      expect(Hecks::Agents::Message.unread).to be_empty
    end
  end
end
