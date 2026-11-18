require "spec_helper"
require_relative "support/agents_message_helpers"

# A message is sent only to a run with a live session; any other recipient is refused by name and
# reaches no inbox.
RSpec.describe "the Agents message recipient" do
  include AgentsMessageHelpers

  before { boot_messages }

  def recipients = { "run-a" => live_run, "run-done" => { status: "finished", session: "d0e5" } }

  def listed_sessions = ["134d89bd"]

  def refusal_for(to) = send_message(to: to).refusal.value.delete_prefix("#{Hecks::Adapters::RecipientCheck::Unaddressable}: ")

  it "refuses a session that has no run, naming it", :aggregate_failures do
    refused = send_message(to: "134d89bd")
    expect(refused.status).to eq("refused")
    expect(refused.refusal.value).to end_with("no run has that id; the session 134d89bd has no AgentRun")
  end

  it "keeps a refused message out of every inbox" do
    send_message(to: "134d89bd")
    expect(inbox("134d89bd")).to be_empty
  end

  it "refuses a run whose session has ended" do
    expect(refusal_for("run-done")).to eq("the run run-done has no live session (finished)")
  end

  it "points a run's own session at its run" do
    expect(refusal_for("5e55")).to eq("5e55 is the session of run run-a; send to the run")
  end

  it "refuses an id that is no run and no session" do
    expect(refusal_for("nobody")).to eq("no run or session has that id: nobody")
  end

  it "sends to a run with a live session" do
    expect(send_message(to: "run-a").status).to eq("sent")
  end

  it "refuses in a boot that holds no AgentRun ledger" do
    expect { Hecks::Adapters::RecipientCheck.new.recipient(recipient: "run-a") }
      .to raise_error(Hecks::Adapters::RecipientCheck::Unaddressable, /not booted here/)
  end
end
