require "spec_helper"
require "hecks/hecks/adapters/dispatching"

# A fill under the Tickets world's `cpu_budget`: with the day's boots under the budget the
# planned work item would start, and with them spent it waits and the report names why. The
# world is the real one, booted in Memory; the work items and the boot record are stand-ins, so
# nothing starts and no live record is read.
RSpec.describe "a fill under the boot budget" do
  let(:plan_item) { Hecks::Adapters::Dispatching::Plan::Item.new(key: "w", title: "w", detail: "", area: ["w"]) }
  let(:work_items) do
    instance_double(Hecks::Adapters::Dispatching::WorkItems, planned: [plan_item], runs: {}, lessons: [], started: [])
  end

  def boots(hours)
    Hecks::Adapters::BootBudget.new(entries: ->(_date) { [{ "boot_ms" => (hours * 3_600_000).to_i }] })
  end

  def settings(hours) = { load: -> { 1.0 }, cpus: 12, work_items: work_items, boots: boots(hours) }

  def preview(hours)
    adapter = Hecks::Adapters::Dispatching.new(registry: boot_hecks_in_memory.registry, settings: settings(hours))
    adapter.preview(repo: { value: "/repo" })[:text]
  end

  it "would start the work item while the boots are under the budget" do
    expect(preview(0.1)).to include("would start w")
  end

  it "leaves the work item waiting, naming the spent budget, once the boots reach it", :aggregate_failures do
    text = preview(1.5)

    expect(text).to include("w skipped: boot budget spent: 1.5 of 1.0 hours")
    expect(text).not_to include("would start w")
  end

  it "declares the budget in the Tickets world" do
    machine = Hecks::Adapters::Dispatching::Settings.new(boot_hecks_in_memory.registry)

    expect(machine.boot_budget).to eq(1.0)
  end
end
