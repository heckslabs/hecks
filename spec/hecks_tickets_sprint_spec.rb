# frozen_string_literal: true

require "spec_helper"

# A sprint is one day's goal and the work items scheduled into it, from any epic. An item sits in at
# most one open sprint; closing a sprint, or scheduling into a closed one, frees the item.
RSpec.describe "the Tickets Sprint" do
  let(:hecks) { boot_hecks_in_memory }

  def cli(*argv)
    Hecks::Adapters::Driving::CliRunner.call(runtime: hecks, program: "hecks", argv: ["tickets", *argv]).first
  end

  def sprint(day, goal = "Goal of #{day}")
    cli("sprint.open!", "sprint.value=#{day}", "goal.value=#{goal}")
  end

  def item(key, epic: nil)
    cli("work.plan!", "work.value=#{key}", "title.value=Item #{key}")
    return unless epic

    cli("epic.open!", "epic.value=#{epic}", "title.value=Epic #{epic}", "outcome.value=Done")
    cli("work.assign!", "to=#{key}", "epic=#{epic}")
  end

  def schedule(key, day) = cli("work.schedule!", "to=#{key}", "sprint=#{day}")

  def plain(value) = value.respond_to?(:value) ? value.value : value

  def aggregate(name) = hecks.registry.bluebook("Tickets").aggregates.find { |declared| declared.hecks_name == name }

  def stored(name) = hecks.registry.repository("Tickets", aggregate(name)).all

  def sprint_of(key) = plain(stored("Work").find { |row| plain(row.work) == key }.sprint)

  def board
    stored("Sprint").map { |row| [plain(row.sprint), plain(row.goal), items_in(plain(row.sprint))] }
  end

  def items_in(day) = stored("Work").select { |row| plain(row.sprint) == day }.map { |row| plain(row.work) }.sort

  it "takes an item of epic A and one of epic B into the same upcoming sprint" do
    sprint("2026-11-23")
    item("a1", epic: "epic-a")
    item("b1", epic: "epic-b")
    schedule("a1", "2026-11-23")
    schedule("b1", "2026-11-23")
    expect(items_in("2026-11-23")).to eq(%w[a1 b1])
  end

  it "refuses an item already in an open sprint a place in a second" do
    sprint("2026-11-23")
    sprint("2026-11-24")
    item("a1")
    schedule("a1", "2026-11-23")
    schedule("a1", "2026-11-24")
    expect(sprint_of("a1")).to eq("2026-11-23")
  end

  it "lists each sprint with its goal and its items" do
    sprint("2026-11-23", "Ship sprints")
    item("a1")
    schedule("a1", "2026-11-23")
    expect(board).to eq([["2026-11-23", "Ship sprints", ["a1"]]])
  end

  it "frees the items of a closed sprint for another sprint" do
    sprint("2026-11-23")
    sprint("2026-11-24")
    item("a1")
    schedule("a1", "2026-11-23")
    cli("sprint.close!", "to=2026-11-23")
    schedule("a1", "2026-11-24")
    expect(sprint_of("a1")).to eq("2026-11-24")
  end

  it "frees an item scheduled into a sprint already closed" do
    sprint("2026-11-23")
    cli("sprint.close!", "to=2026-11-23")
    item("a1")
    schedule("a1", "2026-11-23")
    expect(sprint_of("a1")).to be_nil
  end
end
