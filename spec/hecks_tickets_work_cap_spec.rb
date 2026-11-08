require "spec_helper"
require "hecks/hecks/adapters/work_limits"

# The concurrency cap: a start that would make more started work items than the Tickets world's
# `work_limit` allows goes back to the plan, naming the cap, the count and the holders.
RSpec.describe "the Work concurrency cap" do
  let(:hecks) { boot_hecks_in_memory }

  def cli(*argv)
    out, = Hecks::Adapters::Driving::CliRunner.call(runtime: hecks, program: "hecks", argv: ["tickets", *argv])
    out
  end

  def start(key)
    cli("work.plan!", "work.value=#{key}", "title.value=Step #{key}")
    cli("work.start!", "to=#{key}", "claimed_by.value=s", "claimed_at.value=2026-11-01T09:00:00Z")
    JSON.parse(cli("work.undone")).find { |work| work["work"] == key }
  end

  it "declares a cap of 10 in the Tickets world" do
    expect(Hecks::Adapters::WorkLimits.cap(hecks.registry)).to eq(10)
  end

  it "reads the cap from the world, and falls back to 8 without one", :aggregate_failures do
    world = instance_double(Hecks::Bluebook::World, for_verb: { adapter: "WorkLimits", cap: 3 })
    registry = instance_double(Hecks::Runtime::Registry, world: world)

    expect(Hecks::Adapters::WorkLimits.cap(registry)).to eq(3)
    expect(Hecks::Adapters::WorkLimits.cap(instance_double(Hecks::Runtime::Registry, world: nil))).to eq(8)
  end

  it "falls back to 8 when the world declares a cap with no value" do
    world = instance_double(Hecks::Bluebook::World, for_verb: { adapter: "WorkLimits", cap: nil })

    expect(Hecks::Adapters::WorkLimits.cap(instance_double(Hecks::Runtime::Registry, world: world))).to eq(8)
  end

  it "lets the 10th start through and yields the 11th with its reason", :aggregate_failures do
    tenth = (1..10).map { |n| start("cap/#{n}") }.last
    eleventh = start("cap/11")

    expect(tenth["status"]).to eq("started")
    expect(eleventh["status"]).to eq("planned")
    expect(eleventh["reason"]).to include("11", "cap of 10", "cap/1", "cap/10")
  end

  it "leaves a row that is already started alone when another start is yielded", :aggregate_failures do
    (1..11).each { |n| start("held/#{n}") }

    expect(JSON.parse(cli("work.undone")).count { |work| work["status"] == "started" }).to eq(10)
    expect(start("held/1")["status"]).to eq("started")
  end

  it "admits a start again once a holder finishes" do
    (1..11).each { |n| start("free/#{n}") }
    cli("work.finish!", "to=free/1")
    cli("work.start!", "to=free/11", "claimed_by.value=s", "claimed_at.value=2026-11-01T09:00:00Z")

    expect(JSON.parse(cli("work.undone")).find { |work| work["work"] == "free/11" }["status"]).to eq("started")
  end
end
