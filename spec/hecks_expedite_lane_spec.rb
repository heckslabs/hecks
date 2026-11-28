require "spec_helper"
require "hecks/hecks/adapters/work_limits"
require_relative "support/new_work_started"

# The expedite lane (ADR 0224): a work item `Work.expedite!` marks takes the one place outside the
# cap; a further expedited item takes a regular seat under the cap. The `WorkLimits` port applies
# the one rule in `WorkSlots`.
RSpec.describe "the expedite lane" do
  include_context "with new work started"

  # Scoped to the example group: a top-level `Item` shadows the read-model specs' `Item` aggregate.
  let(:item_record) { Struct.new(:key, :title, :priority) }

  let(:hecks) { boot_hecks_in_memory }
  let(:slots) { Hecks::Adapters::WorkSlots }

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

  def item(key, priority = "") = item_record.new(key, key, priority)

  def held = (1..7).map { |n| item("s-#{n}") }

  def hot(count) = (1..count).map { |n| item("hot-#{n}", "expedite") }

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

  it "records each use as WorkExpedited, saying the priority it set" do
    expedite("hot")
    event = hecks.events.reverse.find { |fired| fired.name.to_s.end_with?("WorkExpedited") }

    expect(event.payload[:priority].value).to eq("expedite")
  end

  it "accepts every priority a work item can hold", :aggregate_failures do
    plan("p")
    %w[expedite now next later].each do |tier|
      tier == "expedite" ? cli("work.expedite!", "to=p") : cli("work.prioritize!", "to=p", "priority.value=#{tier}")
      expect(JSON.parse(cli("work.undone")).find { |work| work["work"] == "p" }["priority"]).to eq(tier)
    end
  end
end
