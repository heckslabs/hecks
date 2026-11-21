require "spec_helper"
require "hecks/hecks/adapters/work_limits"
require_relative "support/new_work_started"

# The expedite lane (ADR 0224): a work item `Work.expedite!` marks starts first after a red fix, in
# the one place outside the cap, past the boot budget and the epic limit, and is held by the load
# only above the CPU count. A further expedited item takes a regular seat under the cap. The
# plan and the `WorkLimits` port apply the one rule in `WorkSlots`.
RSpec.describe "the expedite lane" do
  include_context "with new work started"

  let(:hecks) { boot_hecks_in_memory }
  let(:slots) { Hecks::Adapters::WorkSlots }
  let(:items) { Hecks::Adapters::Dispatching::WorkItems }

  def cli(*argv)
    out, = Hecks::Adapters::Driving::CliRunner.call(runtime: hecks, program: "hecks", argv: ["tickets", *argv])
    out
  end

  def plan(key) = cli("work.plan!", "work.value=#{key}", "title.value=Step #{key}")

  def start(key)
    cli("work.start!", "to=#{key}", "claimed_by.value=s", "claimed_at.value=2026-11-01T09:00:00Z")
    JSON.parse(cli("work.undone")).find { |work| work["work"] == key }
  end

  def fill_cap = (1..Hecks::Adapters::WorkLimits.cap(hecks.registry)).each { |n| plan("held-#{n}") && start("held-#{n}") }

  def expedite(key) = plan(key) && cli("work.expedite!", "to=#{key}")

  # The Tune `WorkCap` record opened at its default level, 4: the cap while the world says it moves.
  def open_moving_cap
    Hecks::Runtime::Dispatcher.new(hecks.registry).dispatch_flat("Hecks::WorkCap.Open", cap: { value: "pipeline" })
  end

  def item(key, priority = "")
    Hecks::Adapters::Dispatching::Plan::Item.new(key: key, title: key, area: [key], priority: priority)
  end

  def held = (1..7).map { |n| item("s-#{n}") }

  def dispatch(planned, started, **limits)
    Hecks::Adapters::Dispatching::Plan.new(planned, started, cap: 7, urgent_reserve: 1, load: 0.0, max_load: 9.0,
                                                             cpus: 12.0, frozen: [], exempt: items.method(:urgent?), **limits)
  end

  it "lists an expedited item after a red one and before priority now" do
    plan("x") && cli("work.prioritize!", "to=x", "priority.value=now")
    expedite("hot") && plan("red-a")

    expect(items.new(hecks.registry).planned.map(&:key)).to eq(%w[red-a hot x])
  end

  it "keeps an expedited item started at a full cap, and holds a second one" do
    fill_cap
    statuses = %w[hot-1 hot-2].map { |key| expedite(key) && start(key)["status"] }

    expect(statuses).to eq(%w[started planned])
  end

  it "takes the place outside the cap without spending the red reserve", :aggregate_failures do
    expect(slots.full?(item("hot", "expedite"), held, cap: 7, reserve: 1)).to be(false)
    expect(slots.full?(item("red-a"), held + [item("hot", "expedite")], cap: 7, reserve: 1)).to be(false)
    expect(slots.full?(item("x"), held.first(6) + [item("hot", "expedite")], cap: 7, reserve: 1)).to be(false)
  end

  it "holds a second expedited item, naming the holder" do
    plan = dispatch([item("hot-2", "expedite")], held + [item("hot-1", "expedite")])

    expect(plan.skipped.map(&:reason)).to eq(["skipped: held: hot-1 holds the one expedite place"])
  end

  def seat_plan(cap, normals, planned) = dispatch(planned, (1..normals).map { |n| item("n-#{n}") }, cap: cap)

  def hot(count) = (1..count).map { |n| item("hot-#{n}", "expedite") }

  it "gives a further expedited item a regular seat ahead of normal work", :aggregate_failures do
    plan = seat_plan(5, 3, hot(3) + [item("x")])

    expect(plan.chosen.map(&:key)).to eq(%w[hot-1 hot-2 hot-3])
    expect(plan.skipped.map(&:key)).to eq(%w[x])
  end

  it "holds a further expedited item naming the holder when no regular seat is free" do
    plan = seat_plan(5, 4, hot(3))

    expect(plan.skipped.map(&:reason)).to eq(["skipped: held: hot-1 holds the one expedite place"])
  end

  it "counts a further expedited holder against a normal item's and a red item's cap", :aggregate_failures do
    holders = held.first(5) + hot(2)

    expect(slots.full?(item("x"), holders, cap: 6, reserve: 1)).to be(true)
    expect(slots.full?(item("red-a"), holders, cap: 6, reserve: 1)).to be(false)
  end

  it "counts a seat for each expedited holder but the first" do
    expect([hot(1), hot(3), held.first(2) + hot(2)].map { |items| slots.seats(items) }).to eq([0, 2, 3])
  end

  it "agrees in the WorkLimits port: a further expedited item starts on a free seat and waits without one" do
    (1..(Hecks::Adapters::WorkLimits.cap(hecks.registry) - 1)).each { |n| plan("held-#{n}") && start("held-#{n}") }
    statuses = %w[hot-1 hot-2 hot-3].map { |key| expedite(key) && start(key)["status"] }

    expect(statuses).to eq(%w[started started planned])
  end

  it "tells Signalbox's admission the seats chosen, a further expedited item among them" do
    seen = []
    admit = Object.new.tap { |door| door.define_singleton_method(:reason) { |_item, chosen:, **| (seen << chosen) && nil } }
    dispatch(hot(2) + [item("x")], [item("n-1")], cap: 5, admit: admit)

    expect(seen).to eq([1])
  end

  it "starts an expedited item over the load limit and under the CPU count, and no other" do
    plan = dispatch([item("hot", "expedite"), item("x")], [], load: 10.5)

    expect([plan.chosen.map(&:key), plan.skipped.map(&:key)]).to eq([%w[hot], %w[x]])
  end

  it "holds an expedited item over the CPU count" do
    plan = dispatch([item("hot", "expedite")], [], load: 12.5)

    expect(plan.skipped.map(&:reason)).to eq(["skipped: load 12.5 > 12.0"])
  end

  it "passes a pause by load and the boot budget, and waits while memory is low", :aggregate_failures do
    hot = [item("hot", "expedite")]

    expect(dispatch(hot, [], paused: Hecks::Adapters::Dispatching::Plan::LOAD_PAUSE, budget: "spent").chosen.size).to eq(1)
    expect(dispatch(hot, [], paused: "skipped: memory low (MemoryLow)").chosen).to be_empty
  end

  it "passes a moving cap below the fixed one with the expedited item, and holds the now one" do
    open_moving_cap && fill_cap
    plan("x") && cli("work.prioritize!", "to=x", "priority.value=now")
    statuses = [start("x")["status"], expedite("hot") && start("hot")["status"]]

    expect([Hecks::Adapters::WorkLimits.cap(hecks.registry), *statuses]).to eq([4, "planned", "started"])
  end

  it "records each use as WorkExpedited, saying the priority the board reads" do
    expedite("hot")
    event = hecks.events.reverse.find { |fired| fired.name.to_s.end_with?("WorkExpedited") }

    expect(event.payload[:priority].value).to eq("expedite")
  end

  it "accepts every priority the dispatcher ranks", :aggregate_failures do
    plan("p")
    items::TIERS.each do |tier|
      out = tier == "expedite" ? cli("work.expedite!", "to=p") : cli("work.prioritize!", "to=p", "priority.value=#{tier}")
      expect(out).not_to include("refused")
    end
  end
end
