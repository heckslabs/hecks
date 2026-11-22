require "spec_helper"
require "hecks/hecks/adapters/dispatching"

# A work item whose area names nothing is held: a fill names why it waits and starts the others.
RSpec.describe "a fill with a work item held for its area" do
  def item(key, held = "")
    Hecks::Adapters::Dispatching::Plan::Item.new(key: key, title: key, detail: "", area: [key], held: held)
  end

  def preview
    items = instance_double(Hecks::Adapters::Dispatching::WorkItems,
                            planned: [item("w1", "w1 area names nothing: lib/nope"), item("w2")], started: [], runs: {})
    Hecks::Adapters::Dispatching.new(settings: { load: -> { 0.5 }, cpus: 4, work_items: items })
                                .preview(repo: "/repo")[:text]
  end

  it "names the held item's words and does not start it", :aggregate_failures do
    expect(preview).to include("w1 skipped: held: w1 area names nothing: lib/nope")
    expect(preview).not_to include("would start w1")
  end

  it "still starts the other item" do
    expect(preview).to include("would start w2")
  end
end
