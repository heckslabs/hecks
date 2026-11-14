require "spec_helper"
require "hecks/hecks/adapters/work_limits"

# The red reserve: a red-* work item starts when the cap of started work items is full, by at most
# `urgent_reserve` places; a second red one waits, and a work item that is not red is refused as
# before. The plan and the `WorkLimits` port apply the same rule, so a chosen red item is not yielded.
RSpec.describe "the cap's reserve for red work" do
  let(:hecks) { boot_hecks_in_memory }
  let(:slots) { Hecks::Adapters::WorkSlots }

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

  def fill_cap = (1..cap).each { |n| start("held-#{n}") }

  def item(key) = Hecks::Adapters::Dispatching::Plan::Item.new(key: key, title: key, area: [key])

  it "declares a reserve of one in the Tickets world" do
    expect(Hecks::Adapters::WorkLimits.urgent_reserve(hecks.registry)).to eq(1)
  end

  it "starts a red work item when every slot is held and keeps it started" do
    fill_cap

    expect(start("red-train-fix")["status"]).to eq("started")
  end

  it "refuses a second red work item once the reserve is spent" do
    fill_cap
    start("red-first")

    expect(start("red-second")["status"]).to eq("planned")
  end

  it "keeps the refusal text of a work item that is not red", :aggregate_failures do
    fill_cap
    over = start("plain-item")

    expect(over["status"]).to eq("planned")
    expect(over["reason"]).to include("cap of #{cap}", "held-1")
  end

  it "plans a red item past a full cap and a second red item not", :aggregate_failures do
    held = (1..7).map { |n| item("s-#{n}") }

    expect(slots.full?(item("red-a"), held, cap: 7, reserve: 1)).to be(false)
    expect(slots.full?(item("red-b"), held + [item("red-a")], cap: 7, reserve: 1)).to be(true)
  end

  it "plans no item that is not red past a full cap, red holders aside", :aggregate_failures do
    held = (1..6).map { |n| item("s-#{n}") } + [item("red-a")]

    expect(slots.full?(item("x"), held, cap: 7, reserve: 1)).to be(false)
    expect(slots.full?(item("x"), held + [item("s-7")], cap: 7, reserve: 1)).to be(true)
  end

  it "lets the dispatch plan choose one red item over a full cap and skip the next", :aggregate_failures do
    held = (1..7).map { |n| item("s-#{n}") }
    plan = Hecks::Adapters::Dispatching::Plan.new([item("red-a"), item("red-b"), item("x")], held, cap: 7,
      urgent_reserve: 1, load: 0.0, max_load: 9.0, frozen: [], exempt: Hecks::Adapters::Dispatching::WorkItems.method(:red?))

    expect(plan.chosen.map(&:key)).to eq(["red-a"])
    expect(plan.skipped.map(&:key)).to eq(%w[red-b x])
  end
end
