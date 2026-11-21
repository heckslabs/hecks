# frozen_string_literal: true

require "spec_helper"
require "hecks/hecks/adapters/dispatching"
require "hecks/roundhouse/adapters/metering"
require_relative "support/recorded_agents_listing"

# The helper share read off a recorded `claude agents --json` listing: runs are found by the short
# listed id the AgentRun ledger keeps, and a finished session whose process lingers counts neither
# as a helper nor as a coder.
RSpec.describe "the helper share over a recorded agents listing" do
  def protecting
    Hecks::Adapters::Dispatching::Protecting.new(
      share: -> {}, sessions: -> { RecordedAgentsListing.metering.rows },
      door: Hecks::Adapters::Dispatching::SignalboxDoor.new
    )
  end

  it "reads three started coders and two live helpers as helpers 2 of 3" do
    expect(protecting.clause).to include("helpers 2 of 3 helpers")
  end
end
