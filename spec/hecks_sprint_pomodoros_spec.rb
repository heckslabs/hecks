require "spec_helper"

# The sprint read: the pomodoros the work items of one sprint were sized at, and the pomodoros they
# spent, which planning leans on as yesterday's weather.
RSpec.describe "the sprint's sized and spent pomodoros" do
  let(:hecks) { boot_hecks_in_memory }
  let(:sprint) { "2026-11-23" }

  def plan(key, sized)
    hecks.dispatch_flat("Tickets::Work.Plan", work: { value: key }, title: { value: key }, detail: { value: "d" },
                                              area: [], pomodoros: { value: sized })
    hecks.dispatch_flat("Tickets::Work.Schedule", work: { value: key }, into: sprint)
  end

  def spend(key, spent)
    hecks.dispatch_flat("Tickets::Work.RecordSpend", work:            { value: key },
                                                     pomodoros_spent: { value: spent })
  end

  def read(name) = hecks.query("Tickets.#{name}").first[:items]

  before do
    Hecks::Runtime::AdapterLookup.standing_in(->(_port, _asked) { Hecks::Adapters::WorkAreas.new(registry: hecks.registry) }) do
      hecks.dispatch_flat("Tickets::Sprint.Open", sprint: { value: sprint }, goal: { value: "g" })
      plan("a", 3)
      plan("b", 2)
    end
    spend("a", 4)
  end

  it "sums what the sprint's items were sized at" do
    expect(read("pomodoros_sized_by_sprint")).to eq(sprint => 5)
  end

  it "sums what the sprint's items spent" do
    expect(read("pomodoros_spent_by_sprint")).to eq(sprint => 4)
  end
end
