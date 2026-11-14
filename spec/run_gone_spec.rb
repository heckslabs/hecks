require "spec_helper"
require "hecks/hecks/adapters/session_lookup"
require "hecks/hecks/adapters/run_gone"
require "hecks/hecks/adapters/run_activity"
require "hecks/hecks/adapters/claude_session_listing"
require "hecks/hecks/adapters/dispatching"

# A run whose session `claude` cannot be asked about is gone only by the world's rule: older than
# its minutes with no process, no commit origin lacks and no changed file.
RSpec.describe Hecks::Adapters::RunGone do
  let(:now) { Time.utc(2026, 11, 14, 12, 0, 0) }
  let(:activity) { instance_double(Hecks::Adapters::RunActivity, process?: false, last_at: nil) }
  let(:rule) { described_class.new(activity, minutes: -> { 60 }, now: -> { now }) }
  let(:listing) { instance_double(Hecks::Adapters::ClaudeSessionListing) }
  let(:lookup) { Hecks::Adapters::SessionLookup.new(listing, grace: -> { 120 }, now: -> { now }, gone: rule) }

  def refusal = (@refusal ||= Hecks::Adapters::ConsoleCapture::Failure.new("claude is not on the path and none of x exists"))

  def held(started_ago = 3 * 3600)
    { run: { value: "r" }, session: { value: "abc123" }, repo: { value: "/tmp/w" },
      started_at: { value: (now - started_ago).iso8601 } }
  end

  before { allow(listing).to receive(:find).and_raise(refusal) }

  it "retires a run with no process, commit or change past the minutes", :aggregate_failures do
    answer = lookup.call(held)

    expect(answer[:listed]).to be(false)
    expect(answer[:note]).to include("cannot be listed", "no process, new commit or changed file for 60 minutes")
  end

  it "keeps a run whose session has a live process" do
    allow(activity).to receive(:process?).and_return(true)

    expect { lookup.call(held) }.to raise_error(refusal)
  end

  it "keeps a run with a fresh commit or change" do
    allow(activity).to receive(:last_at).and_return(now - 600)

    expect { lookup.call(held) }.to raise_error(refusal)
  end

  it "keeps a run started within the minutes" do
    expect { lookup.call(held(600)) }.to raise_error(refusal)
  end
end
