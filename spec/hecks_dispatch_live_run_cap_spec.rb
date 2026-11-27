# frozen_string_literal: true

require "spec_helper"
require "hecks/hecks/adapters/dispatching"

# The cap counts live runs as well as started work items: a planned work item whose run is started
# holds a seat beside the started ones, so a start refused after its launch leaves the cap full and
# not free. A run that ended returns its seat. A turned `dispatch_max_load` dial is read at the
# next beat. The `Dispatching` port is the real adapter over stand-in work items.
RSpec.describe "the cap counts live runs, not work items" do
  def item(key) = Hecks::Adapters::Dispatching::Plan::Item.new(key: key, title: key, detail: "", area: [key])

  def preview(runs)
    work = instance_double(Hecks::Adapters::Dispatching::WorkItems,
                           planned: [item("p-1"), item("p-2")], started: [item("s-1"), item("s-2")],
                           runs: runs, lessons: [], claimant: "a person")
    settings = { sprint: false, load: -> { 1.0 }, cpus: 4, cap: 3, work_items: work }
    Hecks::Adapters::Dispatching.new(settings: settings).preview(repo: { value: "/repo" })[:text]
  end

  it "holds a seat for a planned work item whose run is started", :aggregate_failures do
    text = preview("p-1" => { status: "started", session: "abc" })

    expect(text).to include("started 3 of cap 3")
    expect(text).to include("this fill would start 0", "p-2 skipped: cap 3 reached")
  end

  it "gives the seat back when the run has ended", :aggregate_failures do
    text = preview("p-1" => { status: "finished", session: "abc" })

    expect(text).to include("started 2 of cap 3")
    expect(text).to include("would start p-1")
  end

  it "reads a turned dial at the next beat" do
    world = { "limit" => 16 }
    registry = instance_double(Hecks::Runtime::Registry)
    allow(registry).to receive(:world).with("Tickets").and_return(double(for_verb: { limit: world["limit"] }))
    expect(Hecks::Adapters::Dispatching::Settings.new(registry, cpus: 4).max_load).to eq(16.0)
  end
end
