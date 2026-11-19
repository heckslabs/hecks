require "spec_helper"
require "hecks/hecks/adapters/dispatching"

# A filed stall's work item whose session ended done is finished, so the fill never starts it again.
RSpec.describe Hecks::Adapters::Dispatching::Settler do
  let(:item_class) { Hecks::Adapters::Dispatching::Plan::Item }
  let(:stall_item) { item_class.new(key: "stall-landing-carry-57964c20", title: "S", detail: "", area: []) }
  let(:plain_item) { item_class.new(key: "plain-work", title: "P", detail: "", area: []) }
  let(:launcher) do
    instance_double(Hecks::Adapters::Dispatching::Launcher, check_all: nil, finish: "finished", yield_back: "yielded",
                                                            report_unlanded: "reported")
  end

  def settle(item, condition)
    runs = { item.key => { status: "finished", condition: condition } }
    items = instance_double(Hecks::Adapters::Dispatching::WorkItems, started: [item], runs: runs, landing_in_flight?: false)
    described_class.new(items, launcher, stall: ->(key) { key.start_with?("stall-") }).call
  end

  it "finishes a stall item whose session ended done, and yields nothing", :aggregate_failures do
    settle(stall_item, "done")

    expect(launcher).to have_received(:finish).with(stall_item.key)
    expect(launcher).not_to have_received(:yield_back)
  end

  it "yields a stall item whose session failed" do
    settle(stall_item, "failed")

    expect(launcher).to have_received(:yield_back).with(stall_item, "its session ended failed")
  end

  it "yields a work item that is no stall's whose session ended done with nothing landed", :aggregate_failures do
    settle(plain_item, "done")

    expect(launcher).to have_received(:yield_back).with(plain_item, "its session ended done with no landing or submission")
    expect(launcher).not_to have_received(:finish)
  end
end
