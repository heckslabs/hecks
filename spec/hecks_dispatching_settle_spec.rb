require "spec_helper"
require_relative "support/registry_double"
require "hecks/hecks/adapters/dispatching"

# Settling the started work items, and the settings Dispatch.Fill reads from the Tickets world.
RSpec.describe Hecks::Adapters::Dispatching do
  include RegistryDouble

  let(:work_items) { instance_double(described_class::WorkItems, started: [started_item], runs: runs) }
  let(:launcher) { instance_double(described_class::Launcher, check: nil, finish: "finished a", yield_back: "yielded a") }
  let(:started_item) { described_class::Plan::Item.new(key: "a", title: "A", detail: "", area: []) }

  def world(**verbs)
    instance_double(Hecks::Bluebook::World).tap { |stand_in| allow(stand_in).to receive(:for_verb) { |verb| verbs.fetch(verb.to_sym, {}) } }
  end

  def settings(**verbs)
    described_class::Settings.new(registry_double(world: world(**verbs)), load: -> { 2.0 }, cpus: 6)
  end

  describe "settling" do
    let(:runs) { { "a" => { status: "finished", condition: "done" }, "z" => { status: "finished", condition: "done" } } }

    it "finishes the work item of a session that ended done, and only started work items" do
      described_class::Settler.new(work_items, launcher).call

      expect(launcher).to have_received(:finish).with("a").once
    end

    context "when the session stopped" do
      let(:runs) { { "a" => { status: "finished", condition: "stopped" } } }

      it "yields the work item with the condition as the reason" do
        described_class::Settler.new(work_items, launcher).call

        expect(launcher).to have_received(:yield_back).with("a", "its session ended stopped")
      end
    end

    context "when the session is still running" do
      let(:runs) { { "a" => { status: "started", condition: "" } } }

      it "asks the session and settles nothing", :aggregate_failures do
        lines = described_class::Settler.new(work_items, launcher).call

        expect(lines).to eq([])
        expect(launcher).to have_received(:check).with("a")
      end
    end
  end

  describe "the load reading" do
    it "reads the 1-minute load from macOS and Linux uptime lines", :aggregate_failures do
      expect(described_class::Settings.uptime_load("13:00  up 3 days,  load averages: 23.41 18.00 12.50")).to eq(23.41)
      expect(described_class::Settings.uptime_load(" 13:00:01 up 3 days, load average: 0.52, 0.58, 0.59")).to eq(0.52)
    end

    it "reads the machine when no text is given" do
      expect(described_class::Settings.uptime_load).to be >= 0.0
    end
  end

  describe "the settings" do
    it "stops at the CPU count when the world names no limit" do
      expect(settings.max_load).to eq(6.0)
    end

    it "reads the limit, the frozen areas and the session environment from the world", :aggregate_failures do
      read = settings(dispatch_max_load: { limit: 3 }, frozen_shapes: { areas: ["Fixer"] },
                      session_environment: { cargo_target_dir: "/tmp/cargo", nice: 15 })

      expect([read.max_load, read.frozen, read.session_environment, read.nice])
        .to eq([3.0, ["Fixer"], { "CARGO_TARGET_DIR" => "/tmp/cargo" }, 15])
    end
  end
end
