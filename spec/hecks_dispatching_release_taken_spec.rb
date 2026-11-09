require "spec_helper"
require "hecks/hecks/adapters/dispatching"

# A planned work item parked behind a run still recorded started is never launched, so the retire
# a refused dispatch makes cannot reach it. A confirmed filling asks for that retire itself, so a
# run whose session is gone stops holding the key. The commands are answered by a stand-in runner.
RSpec.describe Hecks::Adapters::Dispatching, "#choose releasing a taken run key" do
  let(:calls) { [] }
  let(:runs) { { "held" => { status: "started" }, "ended" => { status: "finished" }, "slow" => { status: "started" } } }
  let(:planned) { [parked("held", "already_recorded"), parked("ended", "already_recorded"), slow] }
  let(:work_items) do
    instance_double(Hecks::Adapters::Dispatching::WorkItems, planned: planned, runs: runs, lessons: [], started: [])
  end

  def parked(key, kind, **more)
    Hecks::Adapters::Dispatching::Plan::Item.new(key: key, title: key, detail: "", area: [key], yield_kind: kind, **more)
  end

  def slow = parked("slow", "transient", retry_at: (Time.now.utc + 600).iso8601)

  def done = Hecks::Adapters::Shell::Result.new("", "", instance_double(Process::Status, success?: true))

  def adapter
    runner = ->(argv) { (calls << argv) && done }
    described_class.new(registry: boot_hecks_in_memory.registry,
                        settings: { load: -> { 1.0 }, cpus: 12, work_items: work_items, runner: runner })
  end

  def retired
    calls.select { |argv| argv.include?("AgentRun.retire!") }.map { |argv| argv.find { |word| word.start_with?("to=") } }
  end

  it "asks to retire the run behind a parked item that a started run holds" do
    adapter.choose(repo: { value: "/repo" }, confirm: true)

    expect(retired).to eq(["to=held"])
  end

  it "asks for nothing on a dry run, which writes nothing" do
    adapter.preview(repo: { value: "/repo" })

    expect(retired).to be_empty
  end

  it "says a taken run key is held only while its run is started", :aggregate_failures do
    parking = Hecks::Adapters::Dispatching::Parking

    expect(parking.key_held?(planned[0], runs)).to be(true)
    expect(parking.key_held?(planned[1], runs)).to be(false)
    expect(parking.key_held?(planned[2], runs)).to be(false)
  end
end
