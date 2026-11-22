require "spec_helper"
require_relative "support/agents_message_helpers"

# A message body arrives whole, or is refused by name with the limit it broke.
RSpec.describe "the Agents message body limit" do
  include AgentsMessageHelpers

  before { boot_messages }

  def inbox_body(run)
    Hecks::Agents::Message.inbox(recipient: { value: run }).first[:body].value
  end

  it "delivers a body of exactly the limit whole" do
    send_message(body: "q" * 2000)
    expect(inbox_body("run-a")).to eq("q" * 2000)
  end

  it "refuses a body over the limit, naming it" do
    expect { send_message(body: "q" * 2001) }
      .to raise_error(Hecks::Runtime::GivenNotMet, /at most 2000 characters; split it/)
  end

  it "leaves a refused body out of the inbox", :aggregate_failures do
    expect { send_message(body: "q" * 2001) }.to raise_error(Hecks::Runtime::GivenNotMet)
    expect(inbox("run-a")).to be_empty
  end
end
