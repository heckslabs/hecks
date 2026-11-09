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

  def cap = Hecks::Adapters::WorkLimits.cap(hecks.registry)

  it "declares a cap in the Tickets world, not the adapter's default" do
    expect(cap).not_to eq(Hecks::Adapters::WorkLimits::DEFAULT_CAP)
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

  it "lets the last start under the cap through and yields the next with its reason", :aggregate_failures do
    last = (1..cap).map { |n| start("cap/#{n}") }.last
    over = start("cap/#{cap + 1}")

    expect(last["status"]).to eq("started")
    expect(over["status"]).to eq("planned")
    expect(over["reason"]).to include((cap + 1).to_s, "cap of #{cap}", "cap/1", "cap/#{cap}")
  end

  it "leaves a row that is already started alone when another start is yielded", :aggregate_failures do
    (1..(cap + 1)).each { |n| start("held/#{n}") }

    expect(JSON.parse(cli("work.undone")).count { |work| work["status"] == "started" }).to eq(cap)
    expect(start("held/1")["status"]).to eq("started")
  end

  it "admits a start again once a holder finishes" do
    (1..(cap + 1)).each { |n| start("free/#{n}") }
    cli("work.finish!", "to=free/1")
    cli("work.start!", "to=free/#{cap + 1}", "claimed_by.value=s", "claimed_at.value=2026-11-01T09:00:00Z")

    expect(JSON.parse(cli("work.undone")).find { |work| work["work"] == "free/#{cap + 1}" }["status"]).to eq("started")
  end
end
