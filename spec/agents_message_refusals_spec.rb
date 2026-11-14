require "spec_helper"
require_relative "support/agents_message_helpers"

# What a message refuses, each by name.
RSpec.describe "the Agents message refusals" do
  include AgentsMessageHelpers

  before { AgentsMemoryBoot.call }

  it "refuses a second read by the status" do
    read = send_message.read!(reader: { value: "run-a" })
    expect { read.read!(reader: { value: "run-a" }) }.to raise_error(Hecks::Runtime::LifecycleRefused, /read/)
  end

  it "refuses an empty body by name" do
    expect { send_message(body: " ") }.to raise_error(Hecks::Runtime::GivenNotMet, /says something/)
  end

  it "refuses a kind outside the list" do
    expect { send_message(kind: "verdict") }.to raise_error(Hecks::Refused)
  end
end
