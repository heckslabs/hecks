require "spec_helper"
require "hecks/hecks/adapters/dispatching"

# A fill under the Tickets world's `cpu_budget`: with the day's measured boots under the budget the
# planned work item would start, and with them spent it waits and the report names why, except a
# red-* fix, which starts. The world is the real one, booted in Memory; the work items and the boot
# record are stand-ins, so nothing starts and no live record is read.
RSpec.describe "a fill under the boot budget" do
  let(:items) { [plan_item("w")] }
  let(:work_items) do
    instance_double(Hecks::Adapters::Dispatching::WorkItems, planned: items, runs: {}, lessons: [], started: [])
  end

  def plan_item(key) = Hecks::Adapters::Dispatching::Plan::Item.new(key: key, title: key, detail: "", area: [key])

  def boots(hours)
    row = { "boot_ms" => (hours * 3_600_000).to_i, "at" => Time.now.utc.iso8601 }
    Hecks::Adapters::BootBudget.new(entries: ->(_cutoff) { [row] })
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
    text = preview(7.5)

    expect(text).to include("w skipped: boot budget spent: 7.5 of 6.0 hours")
    expect(text).not_to include("would start w")
  end

  context "with a red-* fix planned beside an ordinary item" do
    let(:items) { [plan_item("red-ci"), plan_item("w")] }

    it "starts the fix and holds the ordinary item back", :aggregate_failures do
      text = preview(7.5)

      expect(text).to include("would start red-ci")
      expect(text).to include("w skipped: boot budget spent")
    end
  end

  it "declares the budget in the Tickets world" do
    machine = Hecks::Adapters::Dispatching::Settings.new(boot_hecks_in_memory.registry)

    expect(machine.boot_budget).to eq(6.0)
  end

  # Previews with a boot record that notes each time it is asked, and answers how many times it was.
  def reads_for_a_preview
    reads = []
    counting = Hecks::Adapters::BootBudget.new(entries: ->(cutoff) { (reads << cutoff) && [] })
    adapter = Hecks::Adapters::Dispatching.new(registry: boot_hecks_in_memory.registry,
                                               settings: settings(0.1).merge(boots: counting))
    adapter.preview(repo: { value: "/repo" })
    reads.size
  end

  it "asks the boot record once for a preview, not once for each work item" do
    expect(reads_for_a_preview).to eq(1)
  end
end
