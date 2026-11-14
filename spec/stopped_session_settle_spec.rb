require "spec_helper"
require "hecks/hecks/adapters/session_lookup"
require "hecks/hecks/adapters/run_gone"
require "hecks/hecks/adapters/run_activity"
require "hecks/hecks/adapters/claude_session_listing"
require "hecks/hecks/adapters/dispatching"
require "hecks/runtime/reaction_notice"

# An old started run whose session is stopped or unlisted is asked to retire; no other is.
RSpec.describe Hecks::Adapters::Dispatching::Settler do
  let(:now) { Time.utc(2026, 11, 14, 12, 0, 0) }
  let(:launcher) { instance_double(Hecks::Adapters::Dispatching::Launcher, check_all: nil, retire: nil) }
  let(:sessions) { instance_double(Hecks::Adapters::ClaudeSessionListing) }

  def run(session, ago) = { status: "started", started_at: (now - ago).iso8601, session: session }

  def items
    entry = Hecks::Adapters::Dispatching::Plan::Item.new(key: "a", title: "A", detail: "", area: [])
    runs = { "a" => run("quiet", 7200), "b" => run("busy", 7200), "c" => run("quiet", 60) }
    instance_double(Hecks::Adapters::Dispatching::WorkItems, started: [entry], runs: runs)
  end

  def settle
    world = instance_double(Hecks::Adapters::Dispatching::Settings, claude_missing?: false, run_gone_minutes: 60)
    described_class.new(items, launcher, clock: -> { now }, gone: world, sessions: sessions).call
  end

  before { allow(sessions).to receive(:quiet?) { |id| id == "quiet" } }

  it "asks an old run with a stopped or unlisted session to retire, and no other", :aggregate_failures do
    settle

    expect(launcher).to have_received(:retire).with("a")
    expect(launcher).not_to have_received(:retire).with("b")
    expect(launcher).not_to have_received(:retire).with("c")
  end
end
