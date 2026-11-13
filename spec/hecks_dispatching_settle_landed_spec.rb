require "spec_helper"
require "hecks/hecks/adapters/dispatching"

# A started work item whose branch landed after it started is finished when its session ends,
# never yielded back to the plan: the landing is the work, whatever the session said at its end.
RSpec.describe Hecks::Adapters::Dispatching::Settler do
  let(:item) { Hecks::Adapters::Dispatching::Plan::Item.new(key: "a", title: "A", detail: "", area: []) }
  let(:runs) { { "a" => { status: "finished", condition: "done" } } }
  let(:launcher) do
    instance_double(Hecks::Adapters::Dispatching::Launcher, check_all: nil, finish: "finished a", yield_back: "yielded a",
                                                            report_unlanded: "reported a")
  end

  def settle(landed)
    work_items = instance_double(Hecks::Adapters::Dispatching::WorkItems, started: [item], runs: runs)
    described_class.new(work_items, launcher, landed: ->(key) { landed[key] }).call
  end

  it "finishes a work item whose branch landed, naming the commit", :aggregate_failures do
    lines = settle("a" => "bd4ff9f938bf0b38b8cb2ee53f0ba577a454265f")

    expect(lines).to eq(["finished a: landed as bd4ff9f93, finishing instead"])
    expect(launcher).to have_received(:finish).with("a")
  end

  it "neither yields it nor files it as unlanded", :aggregate_failures do
    settle("a" => "bd4ff9f93")

    expect(launcher).not_to have_received(:yield_back)
    expect(launcher).not_to have_received(:report_unlanded)
  end

  it "yields a work item whose branch did not land since it started" do
    settle({})

    expect(launcher).to have_received(:yield_back).with(item, "its session ended done with no landing or submission")
  end

  context "when the session stopped after the landing" do
    let(:runs) { { "a" => { status: "finished", condition: "stopped" } } }

    it "finishes the work item too" do
      settle("a" => "bd4ff9f93")

      expect(launcher).to have_received(:finish).with("a")
    end
  end
end
