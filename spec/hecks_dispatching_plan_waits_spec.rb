require "spec_helper"
require "hecks/hecks/adapters/dispatching"

# A fill never chooses a work item that waits on an unlanded one, so it is never started and
# yielded for a dependency, and the preview a person reads says which work item it waits on.
RSpec.describe Hecks::Adapters::Dispatching, "#preview" do
  def item(key, detail = "", area: [key]) = described_class::Plan::Item.new(key: key, title: key, detail: detail, area: area)

  def waits = ->(entry) { "skipped: waits on w0" if entry.detail.include?("w0") }

  def plan(items, **limits)
    described_class::Plan.new(items, [], cap: 1, load: 0.5, max_load: 10.0, frozen: [], waits: waits, **limits)
  end

  def preview(landed)
    items = instance_double(described_class::WorkItems, planned: [item("w1", "Depends on: w0"), item("w2")],
                                                        started: [], runs: {}, landed_commits: landed, status_of: "started")
    described_class.new(settings: { load: -> { 0.5 }, cpus: 4, work_items: items, reviews: [] }).preview(repo: "/repo")[:text]
  end

  it "leaves a waiting item out of the cap and the held areas", :aggregate_failures do
    made = plan([item("w1", "Depends on: w0", area: ["lib/x"]), item("w2", area: ["lib/x"])])

    expect(made.chosen.map(&:key)).to eq(["w2"])
    expect(made.skipped.map(&:reason)).to eq(["skipped: waits on w0"])
  end

  it "holds a red item that names an unlanded dependency, whatever it is exempt from" do
    skipped = plan([item("red-main", "Depends on: w0")], exempt: ->(_item) { true }).skipped
    expect(skipped.map(&:reason)).to eq(["skipped: waits on w0"])
  end

  it "says which item it waits on, starts the other, and starts it once that item landed", :aggregate_failures do
    expect(preview([])).to include("w1 skipped: waits on w0").and include("would start w2")
    expect(preview(%w[1111])).to include("would start w1")
  end
end
