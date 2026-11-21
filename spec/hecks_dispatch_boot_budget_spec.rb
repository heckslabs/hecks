require "spec_helper"
require "hecks/hecks/adapters/dispatching"

# A fill under the boot signals the Tickets world declares: a boot storm holds the one caller that
# storms, and the boot share holds every start only at a load over the high mark. The day's boots
# hold nothing. The world is the real one, booted in Memory; the work items and the boot record
# are stand-ins, so nothing starts and no live record is read.
RSpec.describe "a fill under the boot signals" do
  let(:items) { [plan_item("w"), plan_item("x")] }
  let(:work_items) do
    instance_double(Hecks::Adapters::Dispatching::WorkItems, planned: items, runs: {}, lessons: [], started: [])
  end
  let(:now) { Time.now.utc }

  def plan_item(key) = Hecks::Adapters::Dispatching::Plan::Item.new(key: key, title: key, detail: "", area: [key])

  def run(boot_ms, caller_name = nil, minutes_ago = 1)
    { "boot_ms" => boot_ms, "caller" => caller_name, "at" => (now - (minutes_ago * 60)).iso8601 }.compact
  end

  def preview(rows, load: 1.0)
    boots = Hecks::Adapters::BootBudget.new(entries: ->(_cutoff) { rows }, now: -> { now })
    settings = { load: -> { load }, cpus: 12, work_items: work_items, boots: boots }
    adapter = Hecks::Adapters::Dispatching.new(registry: boot_hecks_in_memory.registry, settings: settings)
    adapter.preview(repo: { value: "/repo" })[:text]
  end

  it "starts work on a busy, healthy day whose boot share is low", :aggregate_failures do
    text = preview([run(3_600_000 * 7, nil, 600), run(100_000)])

    expect(text).to include("would start w")
    expect(text).to include("would start x")
  end

  it "holds one looping caller's own work item while the other starts", :aggregate_failures do
    text = preview(Array.new(31) { run(1, "coder:w") })

    expect(text).to include("w skipped: boot storm: coder:w booted 31 times in 5 minutes")
    expect(text).to include("would start x")
  end

  it "does not hold on a boot-heavy minute at a load under the high mark" do
    expect(preview([run(3_600_000)], load: 3.0)).to include("would start w")
  end

  it "holds every start when the boot share is over its mark and the load over the high mark", :aggregate_failures do
    text = preview([run(3_600_000)], load: 11.0)

    expect(text).to include("boot share 33.3% of CPU over 25.0% in the last 15 minutes")
    expect(text).not_to include("would start w")
  end

  it "declares the day's hours in the Tickets world as a reading" do
    machine = Hecks::Adapters::Dispatching::Settings.new(boot_hecks_in_memory.registry)

    expect(machine.boot_budget).to eq(6.0)
  end

  # Previews with a boot record that notes each time it is asked, and answers how many times it was.
  def reads_for_a_preview
    reads = []
    counting = Hecks::Adapters::BootBudget.new(entries: ->(cutoff) { (reads << cutoff) && [] })
    adapter = Hecks::Adapters::Dispatching.new(registry: boot_hecks_in_memory.registry,
                                               settings: { load: -> { 1.0 }, cpus: 12, work_items: work_items, boots: counting })
    adapter.preview(repo: { value: "/repo" })
    reads.size
  end

  it "reads each boot window once for a preview, not once for each work item" do
    expect(reads_for_a_preview).to be <= 2
  end
end
