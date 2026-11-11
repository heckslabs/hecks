require "spec_helper"
require "hecks/hecks/adapters/dispatching"

# A fill reads the PlanReview rows through the `reviews:` stand-in: the third rethink holds a work
# item for a person by name and the others still start.
RSpec.describe "a fill after the architect's rethinks" do
  def review(work, index) = { run: "#{work}-#{index}", work: work, verdict: "rethink", findings: "f" }

  def item(key) = Hecks::Adapters::Dispatching::Plan::Item.new(key: key, title: key, detail: "", area: [key])

  def preview(count)
    items = instance_double(Hecks::Adapters::Dispatching::WorkItems, planned: [item("w1"), item("w2")], started: [], runs: {})
    reviews = Array.new(count) { |index| review("w1", index) }
    Hecks::Adapters::Dispatching.new(settings: { load: -> { 0.5 }, cpus: 4, work_items: items, reviews: reviews })
                                .preview(repo: "/repo")[:text]
  end

  it "skips the item at its third rethink by name and still starts the other", :aggregate_failures do
    text = preview(3)

    expect(text).to include("w1 skipped: needs a person: 3 architect rethinks (w1-0, w1-1, w1-2)")
    expect(text).to include("would start w2")
  end

  it "starts an item at its second rethink" do
    expect(preview(2)).to include("would start w1")
  end
end
