require "spec_helper"
require_relative "support/epic_outcome_looks"

# The `OutcomeReadings` adapter reads one number from the event tap as an `OutcomeMeasure` row says,
# and answers it beside the row's bounds. It judges nothing: the Epic's commands compare them.
RSpec.describe Hecks::Adapters::OutcomeReadings do
  include_context "with an epic outcome tap"

  def read(measure)
    epic(measure)
    described_class.new(registry: hecks.registry, tap: tap).read_outcome(epic: { value: "e1" })
  end

  def started(id, *minutes_ago) = minutes_ago.map { |ago| ["Tickets::Work", "WorkStarted", id, ago] }

  it "counts the row's events inside its window", :aggregate_failures do
    write_tap(*load_rose(5, 20, 61), ["Hecks::Machine", "LoadFellBelow", "beat-9", 4])

    expect(read("load-stays-under-its-mark")).to include(reading: { value: 2 }, at_least: { value: 0 }, at_most: { value: 0 })
  end

  it "reads the most lines one id records within the row's span" do
    write_tap(*started("a", 30, 30, 10), *started("b", 12))

    expect(read("no-item-started-twice-a-minute")[:reading]).to eq(value: 2)
  end

  it "reads a floor for a row that wants at least some", :aggregate_failures do
    write_tap(["Hecks::Integration", "MainVerified", "c1", 10])
    answer = read("main-is-verified-three-times")

    expect(answer).to include(reading: { value: 1 }, at_least: { value: 3 })
    expect(answer[:at_most][:value]).to be > 1000
  end

  it "names the next evidence item of the epic" do
    hecks
    epic
    cli("work.plan!", "work.value=e1-outcome-1", "title.value=Earlier evidence")
    answer = described_class.new(registry: hecks.registry, tap: tap).read_outcome(epic: { value: "e1" })

    expect(answer[:finding]).to eq(value: "e1-outcome-2")
  end

  it "refuses to read with no event tap" do
    epic
    adapter = described_class.new(registry: hecks.registry, tap: nil)

    expect { adapter.read_outcome(epic: { value: "e1" }) }.to raise_error(/no event tap/)
  end

  it "gives every tier-1 measure row an aggregate, an event and a window", :aggregate_failures do
    rows = described_class.new(registry: hecks.registry, tap: tap).rows

    expect(rows.size).to be >= 4
    expect(rows).to all(include(:measure, :aggregate, :events, :minutes))
  end
end
