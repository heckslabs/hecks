require "spec_helper"
require_relative "support/roll_forward_fixtures"

# A work item yielded for load (`yield_kind` load, the Tickets `YieldKind` row) is restarted first
# when the load falls: it leads the plan after red, rolls with no priority of its own and waits
# out no backoff.
RSpec.describe "a work item yielded for load", :aggregate_failures do
  include RollForwardFixtures

  def entries
    [entry("planned-now", priority: "now"), shed("shed-later", "later"), shed("shed-next", "next"), shed("shed-none", nil),
     entry("red-main")]
  end

  def shed(key, priority) = entry(key, priority: priority).tap { |row| row.yield_kind = "load" }

  def work_items = Hecks::Adapters::Dispatching::WorkItems.new(registry_of(entries))

  def plan(load)
    Hecks::Adapters::Dispatching::Plan.new(work_items.rollable, [], cap: 5, load: load, max_load: 10.0, frozen: [])
  end

  it "leads the plan after red, by priority" do
    expect(work_items.planned.map(&:key)).to eq(%w[red-main shed-next shed-later shed-none planned-now])
  end

  it "rolls without a priority of its own" do
    expect(work_items.rollable.map(&:key)).to include("shed-none")
  end

  it "starts in the fill that follows a fall, and waits while the load is over the limit" do
    expect(plan(9.0).chosen.map(&:key).first(2)).to eq(%w[red-main shed-next])
    expect(plan(11.0).chosen).to be_empty
  end

  # The `YieldKind` rows of the Tickets bluebook, and the parking they describe.
  def rows
    work = boot_hecks_in_memory(File.expand_path("../lib/hecks/hecks", __dir__)).registry.bluebook("Tickets").aggregate("Work")
    work.value_objects.find { |object| object.hecks_name == "YieldKind" }.members
  end

  it "never parks a load yield on a retry time" do
    item = Hecks::Adapters::Dispatching::Plan::Item.new(key: "a", yield_kind: "load", retry_at: (Time.now.utc + 600).iso8601)

    expect(Hecks::Adapters::Dispatching::Parking.reason(item, runs: -> { {} })).to be_nil
  end

  it "declares what each kind waits for, and that a load yield counts nothing and restarts first" do
    expect(rows.to_h { |row| [row[:kind], row[:waits]] })
      .to eq("transient" => "time", "missing_passage" => "time", "already_recorded" => "run", "load" => "load")
    expect(rows.find { |row| row[:kind] == "load" }).to include(counted: false, first: true)
  end
end
