require "spec_helper"
require "hecks/hecks/adapters/dispatching"

# A fill's report names the source of the load it compared with its limit and states the sampler's
# newest reading beside it, saying so when the two stand more than 2 apart. The limit stays on the
# `uptime` figure: the sampler's reading carries no time, so a stopped sampler cannot clear a load.
RSpec.describe Hecks::Adapters::Dispatching::LoadReading do
  let(:items_class) { Hecks::Adapters::Dispatching::WorkItems }
  let(:item) { Hecks::Adapters::Dispatching::Plan::Item.new(key: "w0", title: "w0", detail: "", area: ["w0"]) }

  def work_items = instance_double(items_class, planned: [item], started: [], runs: {})

  def report(uptime:, loads:)
    stand_ins = { load: -> { uptime }, cpus: 10, cap: 8, work_items: work_items, reviews: [], loads: loads }
    Hecks::Adapters::Dispatching.new(settings: stand_ins).preview(repo: "/repo")[:text]
  end

  def header(**held) = report(**held).lines.first

  it "names uptime as the source and states a differing sampler reading", :aggregate_failures do
    text = header(uptime: 9.0, loads: [8.0, 4.6])

    expect(text).to include("load 9.0 (limit 10.0, 10 cpus)", "load source: uptime 9.0 at 20")
    expect(text).to include("sampler 4.6 differs by 4.4 (over 2.0)")
  end

  it "states the newest sampler reading without a disagreement inside 2", :aggregate_failures do
    text = header(uptime: 9.0, loads: [3.0, 8.0])

    expect(text).to include("sampler 8.0;")
    expect(text).not_to include("differs")
  end

  it "says no sampler reading is recorded when there is none" do
    expect(header(uptime: 3.0, loads: [])).to include("sampler reading none recorded")
  end

  it "does not let a low sampler reading clear a load over the limit" do
    expect(report(uptime: 14.0, loads: [4.6])).to include("skipped: load 14.0 > 10.0: nothing starts")
  end
end
