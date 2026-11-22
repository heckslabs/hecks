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
    Hecks::Agents::Message.find("m1").escalate!(now: { value: 2_000 })
    expect { fall_back("m1", 2_200) }.to raise_error(Hecks::Runtime::GivenNotMet, /waited/)
  end
end
