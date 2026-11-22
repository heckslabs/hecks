require "spec_helper"
require_relative "support/agents_message_helpers"

# A sent message wakes whichever session holds its recipient's role name: an idle one is resumed, a
# busy one hears it at its next tool call, and a role nobody holds leaves the message resting.
RSpec.describe "the Agents message wake" do
  include AgentsMessageHelpers

  before { boot_messages }

  def role_sessions = @role_sessions ||= [{ "id" => "ab12", "name" => "orchestrator", "status" => "idle", "state" => "idle" }]

  def recorded = @agents_runtime.events.map { |event| event.respond_to?(:name) ? event.name : event[:name] }.map(&:to_s)

  it "wakes an idle session holding the role name", :aggregate_failures do
    send_message(to: "orchestrator")
    expect(recorded).to include("MessageWoken")
    expect(resumed.map(&:first)).to eq(["ab12"])
  end

  it "does not resume a busy session, whose hook delivers the mail", :aggregate_failures do
    role_sessions.first.merge!("status" => "busy", "state" => "working")
    send_message(to: "orchestrator")
    expect(recorded).to include("MessageWoken")
    expect(resumed).to be_empty
  end

  it "leaves the message resting when no session holds the role", :aggregate_failures do
    role_sessions.clear
    expect(send_message(to: "orchestrator").status).to eq("sent")
    expect(recorded).to include("WakeUnreachable")
  end

  it "knows a session by its role name followed by a number", :aggregate_failures do
    role_sessions.first["name"] = "orchestrator 2"
    send_message(to: "orchestrator")
    expect(resumed.map(&:first)).to eq(["ab12"])
  end

  it "wakes a session listed idle whatever its state says", :aggregate_failures do
    role_sessions.first.merge!("status" => "idle", "state" => "working", "sessionId" => "ab12-full")
    send_message(to: "orchestrator")
    expect(resumed.map(&:first)).to eq(["ab12"])
    expect(resumed_entries.first["sessionId"]).to eq("ab12-full")
  end

  it "prefers the seat listed idle over a second seat that is busy", :aggregate_failures do
    role_sessions.first.merge!("status" => "idle", "state" => "working")
    role_sessions << { "id" => "cd34", "name" => "orchestrator 2", "status" => "busy", "state" => "working" }
    send_message(to: "orchestrator")
    expect(resumed.map(&:first)).to eq(["ab12"])
  end
end
