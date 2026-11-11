require "spec_helper"
require "hecks/hecks/adapters/dispatching"

# What the examples share: a clock fixed at the misfire's second, and a run that started so long ago.
module SettleYoungHelpers
  def now = Time.utc(2026, 11, 11, 2, 11, 3)

  def entry = Hecks::Adapters::Dispatching::Plan::Item.new(key: "a", title: "A", detail: "", area: [])

  def settler = described_class.new(items, launcher, grace: 120, clock: -> { now })

  def launcher
    @launcher ||= instance_double(Hecks::Adapters::Dispatching::Launcher, yield_back: "y", report_unlanded: "r", check_all: nil)
  end

  def items = instance_double(Hecks::Adapters::Dispatching::WorkItems, started: [entry], runs: runs)

  def run_started(seconds_ago, condition: "done")
    { "a" => { status: "finished", condition: condition, started_at: (now - seconds_ago).iso8601 } }
  end
end

# A session read in its first seconds is unknown, not done: the settler leaves its Work item alone
# until the run is older than session_grace, and files no Finding for it.
RSpec.describe Hecks::Adapters::Dispatching::Settler do
  include SettleYoungHelpers

  context "when the run started eight seconds ago" do
    let(:runs) { run_started(8) }

    it "yields nothing and files no finding", :aggregate_failures do
      settler.call

      expect(launcher).not_to have_received(:yield_back)
      expect(launcher).not_to have_received(:report_unlanded)
    end
  end

  context "when the run started past the grace" do
    let(:runs) { run_started(300) }

    it "yields the item and files the finding", :aggregate_failures do
      settler.call

      expect(launcher).to have_received(:yield_back)
      expect(launcher).to have_received(:report_unlanded).with("a")
    end
  end

  context "when the run records no start" do
    let(:runs) { { "a" => { status: "finished", condition: "stopped", started_at: "" } } }

    it "counts as old" do
      settler.call

      expect(launcher).to have_received(:yield_back)
    end
  end
end
