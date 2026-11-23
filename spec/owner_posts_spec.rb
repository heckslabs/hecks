# frozen_string_literal: true

require "spec_helper"
require_relative "support/agents_message_helpers"
require "hecks/pipeline_board/adapters/pipeline_web"

# The owner posts from the board and the terminal as `owner`, and mail addressed to `owner` is
# sent, not refused, so it shows in the owner's inbox.
RSpec.describe "the owner's messages" do
  include AgentsMessageHelpers

  before { boot_messages }

  it "sends a message addressed to the owner", :aggregate_failures do
    expect(send_message(to: "owner", sender: "scrum-master", kind: "question").status).to eq("sent")
    expect(inbox("owner")).to eq(["m1"])
  end

  it "keeps the owner's own post to a run as the owner's words", :aggregate_failures do
    posted = send_message(to: "run-a", sender: "owner", kind: "owner")
    expect(posted.status).to eq("sent")
    expect(posted.sender.value).to eq("owner")
  end

  it "gives the board a post step that sends as the owner", :aggregate_failures do
    rule = Hecks::Adapters::PipelineBoard::Rules.action("post")
    expect(rule[:needs]).to eq(%i[target text])
    expect(rule[:argv]).to include("Message.send!", "sender=owner")
  end
end
