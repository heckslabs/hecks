# frozen_string_literal: true

require "spec_helper"
require "hecks/roundhouse/adapters/metering"
require_relative "support/recorded_agents_listing"

# The meter finds a session's run by the short id `claude agents` lists, which is the key the
# AgentRun ledger records, and still by the full session id.
RSpec.describe Hecks::Adapters::Metering::SessionRuns do
  let(:entry) { { "id" => "c0de0001", "sessionId" => "c0de0001-0000-4000-8000-000000000001" } }

  it "finds a run kept under the listed short id" do
    expect(described_class.of({ "c0de0001" => { run: "short" } }, entry)).to eq(run: "short")
  end

  it "finds a run kept under the full session id" do
    expect(described_class.of({ entry["sessionId"] => { run: "full" } }, entry)).to eq(run: "full")
  end

  it "reads a coder run keyed by its short id as a coder on the meter" do
    roles = RecordedAgentsListing.metering.rows.to_h { |row| [row[:id], row[:role]] }
    expect(roles.values_at("c0de0001", "c0de0002", "c0de0003")).to eq(%w[coder coder coder])
  end

  it "gives a finished session's ended row its run" do
    ended = RecordedAgentsListing.metering.ended_facts[:sessions].find { |row| row[:id] == "d0ee0001" }
    expect(ended).to include(role: "coder", run: "item-d")
  end
end
