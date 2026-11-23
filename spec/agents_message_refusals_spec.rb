require "spec_helper"
require_relative "support/agents_message_helpers"

# What a message refuses, each by name.
RSpec.describe "the Agents message refusals" do
  include AgentsMessageHelpers

  before { boot_messages }

  it "refuses a second read by the status" do
    read = send_message.read!(reader: { value: "run-a" })
    expect { read.read!(reader: { value: "run-a" }) }.to raise_error(Hecks::Runtime::LifecycleRefused, /read/)
  end

  it "refuses an empty body by name" do
    expect { send_message(body: " ") }.to raise_error(Hecks::Runtime::GivenNotMet, /says something/)
  end

  %w[notice tonight].each do |kind|
    it "refuses the kind #{kind} naming the declared kinds" do
      expect { send_message(kind: kind) }
        .to raise_error(Hecks::Refused, /MessageKind admits "help".*"person" — got "#{kind}"/)
    end
  end
end
