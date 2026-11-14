require "spec_helper"
require "hecks/hecks/adapters/dispatching"

# While `claude` cannot be run, the settle asks each old started run to retire; the run's own
# lookup then keeps or retires it by the world's rule.
RSpec.describe Hecks::Adapters::Dispatching::Settler do
  let(:now) { Time.utc(2026, 11, 14, 12, 0, 0) }
  let(:launcher) { instance_double(Hecks::Adapters::Dispatching::Launcher, check_all: nil, retire: nil) }

  def items
    entry = Hecks::Adapters::Dispatching::Plan::Item.new(key: "a", title: "A", detail: "", area: [])
    runs = { "a" => { status: "started", started_at: (now - 7200).iso8601 },
             "b" => { status: "started", started_at: now.iso8601 } }
    instance_double(Hecks::Adapters::Dispatching::WorkItems, started: [entry], runs: runs)
  end

  def settle(missing:)
    world = instance_double(Hecks::Adapters::Dispatching::Settings, claude_missing?: missing, run_gone_minutes: 60)
    described_class.new(items, launcher, clock: -> { now }, gone: world).call
  end

  it "asks the old started run to retire while claude is missing, and no other", :aggregate_failures do
    settle(missing: true)

    expect(launcher).to have_received(:retire).with("a")
    expect(launcher).not_to have_received(:retire).with("b")
  end

  it "asks nothing to retire while claude can list sessions" do
    settle(missing: false)

    expect(launcher).not_to have_received(:retire)
  end
end
