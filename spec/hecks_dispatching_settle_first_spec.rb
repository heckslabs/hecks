require "spec_helper"
require "hecks/hecks/adapters/dispatching"

# A confirmed filling settles the ended sessions before it counts the started work items, so the
# cap holds only live work. A preview writes nothing, so it settles nothing.
RSpec.describe Hecks::Adapters::Dispatching, "#choose" do
  let(:item_class) { described_class::Plan::Item }
  let(:calls) { [] }
  let(:done) { [] }
  let(:ended) { item_class.new(key: "ended", title: "E", detail: "", area: []) }
  let(:waiting) { item_class.new(key: "waiting", title: "W", detail: "", area: []) }

  def started_now = done.include?("ended") ? [] : [ended]

  def stand_in_items
    items = instance_double(described_class::WorkItems, planned: [waiting], rollable: [waiting], lessons: [])
    allow(items).to receive(:started) { started_now }
    allow(items).to receive(:runs).and_return("ended" => { status: "finished", condition: "done" })
    items
  end

  def runner
    lambda do |argv|
      calls << argv
      done << "ended" if argv.include?("Work.yield!") && argv.include?("to=ended")
      Hecks::Adapters::Shell::Result.new("", "", instance_double(Process::Status, success?: true))
    end
  end

  def dispatching(cap: 1)
    described_class.new(settings: { load: -> { 0.5 }, cpus: 4, cap: cap, work_items: stand_in_items, runner: runner })
  end

  def settles = calls.count { |argv| argv.include?("Work.yield!") && argv.include?("to=ended") }

  it "settles the ended work item before a confirmed filling counts started rows", :aggregate_failures do
    report = dispatching.choose(repo: { value: "/repo" }, confirm: true).dig(:report, :value)

    expect(settles).to eq(1)
    expect(report).to include("started 0 of cap 1")
  end

  it "settles nothing in a preview" do
    dispatching.preview(repo: { value: "/repo" })

    expect(settles).to eq(0)
  end

  it "settles nothing in a dry filling" do
    dispatching.choose(repo: { value: "/repo" })

    expect(settles).to eq(0)
  end

  it "settles once when a roll fills" do
    Hecks::Adapters::Dispatching::LastRoll.reset!
    dispatching.roll

    expect(settles).to eq(1)
  end
end
