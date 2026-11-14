require "spec_helper"
require "hecks/hecks/adapters/session_lookup"
require "hecks/hecks/adapters/run_gone"
require "hecks/hecks/adapters/run_activity"
require "hecks/hecks/adapters/claude_session_listing"
require "hecks/hecks/adapters/dispatching"
require "hecks/runtime/reaction_notice"

# A started run whose session `claude` lists `stopped` is gone once it has shown nothing for the
# declared minutes; a session that works or waits is never gone, whatever its age.
RSpec.describe Hecks::Adapters::SessionLookup do
  let(:now) { Time.utc(2026, 11, 14, 12, 0, 0) }
  let(:activity) { instance_double(Hecks::Adapters::RunActivity, process?: false, last_at: nil) }
  let(:rule) { Hecks::Adapters::RunGone.new(activity, minutes: -> { 60 }, stopped: -> { 60 }, now: -> { now }) }
  let(:listing) { instance_double(Hecks::Adapters::ClaudeSessionListing) }
  let(:lookup) { described_class.new(listing, grace: -> { 120 }, now: -> { now }, gone: rule) }

  def held(started_ago = 3 * 3600)
    { run: { value: "r" }, session: { value: "abc123" }, repo: { value: "/tmp/w" },
      started_at: { value: (now - started_ago).iso8601 } }
  end

  def listed_as(state) = allow(listing).to receive(:find).and_return({ "id" => "abc123", "state" => state })

  it "retires a stopped session over an old started run", :aggregate_failures do
    listed_as("stopped")
    answer = lookup.call(held)

    expect(answer[:listed]).to be(false)
    expect(answer[:note]).to include("listed stopped", "no process, new commit or changed file for 60 minutes")
  end

  %w[done failed].each do |state|
    it "retires a #{state} session over an old started run", :aggregate_failures do
      listed_as(state)
      answer = lookup.call(held)

      expect(answer[:listed]).to be(false)
      expect(answer[:note]).to include("listed #{state}")
    end
  end

  it "keeps a stopped session over a young run" do
    listed_as("stopped")

    expect(lookup.call(held(600))[:listed]).to be(true)
  end

  %w[working waiting blocked].each do |state|
    it "keeps a #{state} session whatever the run's age" do
      listed_as(state)

      expect(lookup.call(held(30 * 24 * 3600))[:listed]).to be(true)
    end
  end

  it "keeps a stopped session whose run has a live process" do
    listed_as("stopped")
    allow(activity).to receive(:process?).and_return(true)

    expect(lookup.call(held)[:listed]).to be(true)
  end

  it "keeps a stopped session whose run has a fresh commit" do
    listed_as("stopped")
    allow(activity).to receive(:last_at).and_return(now - 600)

    expect(lookup.call(held)[:listed]).to be(true)
  end
end
