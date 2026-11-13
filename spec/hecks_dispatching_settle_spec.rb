require "spec_helper"
require_relative "support/registry_double"
require_relative "support/agent_run_records"
require "hecks/hecks/adapters/dispatching"

# Settling the started work items, and the settings Dispatch.Fill reads from the Tickets world.
RSpec.describe Hecks::Adapters::Dispatching do
  include RegistryDouble

  let(:work_items) { instance_double(described_class::WorkItems, started: [started_item], runs: runs) }
  let(:launcher) do
    instance_double(described_class::Launcher, check_all: nil, finish: "finished a", yield_back: "yielded a",
                                               report_unlanded: "reported a")
  end
  let(:started_item) { described_class::Plan::Item.new(key: "a", title: "A", detail: "", area: []) }

  def world(**verbs)
    instance_double(Hecks::Bluebook::World).tap { |stand_in| allow(stand_in).to receive(:for_verb) { |verb| verbs.fetch(verb.to_sym, {}) } }
  end

  def settings(**verbs)
    described_class::Settings.new(registry_double(world: world(**verbs)), load: -> { 2.0 }, cpus: 6)
  end

  describe "settling" do
    let(:runs) { { "a" => { status: "finished", condition: "done" }, "z" => { status: "finished", condition: "done" } } }

    it "never finishes a started work item itself: a landing or a submission finishes it" do
      described_class::Settler.new(work_items, launcher).call

      expect(launcher).not_to have_received(:finish)
    end

    it "yields a started item whose session ended done with nothing landed, and files a finding", :aggregate_failures do
      described_class::Settler.new(work_items, launcher).call

      expect(launcher).to have_received(:yield_back).with(started_item, "its session ended done with no landing or submission")
      expect(launcher).to have_received(:report_unlanded).with("a").once
    end

    context "when the session stopped" do
      let(:runs) { { "a" => { status: "finished", condition: "stopped" } } }

      it "yields the work item itself, which carries its yield count, with the condition as the reason" do
        described_class::Settler.new(work_items, launcher).call

        expect(launcher).to have_received(:yield_back).with(started_item, "its session ended stopped")
      end
    end

    context "when the session is still running" do
      let(:runs) { { "a" => { status: "started", condition: "" } } }

      it "asks the session and settles nothing", :aggregate_failures do
        lines = described_class::Settler.new(work_items, launcher).call

        expect(lines).to eq([])
        expect(launcher).to have_received(:check_all)
      end
    end

    context "when the run is live and an archived run of the same key ended" do
      include AgentRunRecords

      it "yields nothing, since the live run holds the key" do
        items = work_items_over(run_record("a", "started"), run_record("a~1", "finished"))
        allow(items).to receive(:started).and_return([started_item])
        described_class::Settler.new(items, launcher).call

        expect(launcher).not_to have_received(:yield_back)
      end
    end

    context "when several sessions are still running" do
      let(:runs) { { "a" => { status: "started", condition: "" }, "b" => { status: "started", condition: "" } } }
      let(:work_items) { instance_double(described_class::WorkItems, started: [started_item, second_item], runs: runs) }
      let(:second_item) { described_class::Plan::Item.new(key: "b", title: "B", detail: "", area: []) }

      it "checks them all in one launcher call" do
        described_class::Settler.new(work_items, launcher).call

        expect(launcher).to have_received(:check_all).once
      end
    end

    context "when no session is started" do
      let(:runs) { { "a" => { status: "finished", condition: "done" } } }

      it "does not boot a launcher to check" do
        described_class::Settler.new(work_items, launcher).call

        expect(launcher).not_to have_received(:check_all)
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
