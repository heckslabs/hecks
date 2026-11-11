require "spec_helper"
require "hecks/hecks/adapters/dispatching"

# A preview under a load over the limit says so once and reads the queue once: the 300 planned
# items collapse to one line, and no item costs a read of the runs or the reviews.
RSpec.describe "a preview while the load blocks every start" do
  let(:items_class) { Hecks::Adapters::Dispatching::WorkItems }

  def item(key) = Hecks::Adapters::Dispatching::Plan::Item.new(key: key, title: key, detail: "", area: [key])

  def work_items
    @work_items ||= instance_double(items_class, planned: Array.new(300) { |i| item("w#{i}") }, started: [], runs: {})
  end

  def preview
    Hecks::Adapters::Dispatching.new(settings: { load: -> { 8.3 }, cpus: 8, cap: 8, work_items: work_items, reviews: [] })
                                .preview(repo: "/repo")[:text]
  end

  it "answers in one line naming the count and the first items", :aggregate_failures do
    lines = preview.lines.map(&:chomp)

    expect(lines.size).to eq(2)
    expect(lines.last).to eq("skipped: load 8.3 > 8.0: nothing starts; 300 waiting, first w0, w1, w2")
  end

  it "reads the planned items once and the runs at most once", :aggregate_failures do
    preview

    expect(work_items).to have_received(:planned).once
    expect(work_items).to have_received(:runs).at_most(:once)
  end
end
