# frozen_string_literal: true

require "spec_helper"
require_relative "support/help_queue_calls"

# The one line a call for help the owner is shown reads as: what it needs and how long its block
# has stood.
RSpec.describe "the line of a call for help on the Waiting-on-you panel" do
  include HelpQueueCalls

  it "says the age in whole hours, then in days", :aggregate_failures do
    expect(shown(call(role: "owner", minutes: 185))).to eq(["needs you: login for X, 3h"])
    expect(shown(call(role: "owner", minutes: 3000))).to eq(["needs you: login for X, 2d"])
  end

  it "shows the owner's call with no age when its opening time cannot be read" do
    expect(shown(call(role: "owner").merge(opened_at: "soon"))).to eq(["needs you: login for X, age unknown"])
  end

  it "answers no lines and the reason when the calls could not be read" do
    reading = Hecks::Adapters::PipelineBoard::HelpQueue.reading({ unknown: "no store" }, HelpQueueCalls::NOW)
    expect(reading).to eq(help: [], help_unknown: "no store")
  end

  it "lists one line per call, in the order they were read" do
    calls = %w[a b].map { |needs| call(role: "owner", needs: needs) }
    expect(shown(*calls)).to eq(["needs you: a, 5m", "needs you: b, 5m"])
  end
end
