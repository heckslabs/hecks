require "spec_helper"
require "tmpdir"
require "hecks/hecks/adapters/dispatching"

# The launcher's boot budget: the measured hours of boots in the 24 hours before now, and who
# booted in the last hour. The usage record is a stand-in, so the live record is never read.
RSpec.describe "the boot budget" do
  let(:now) { Time.utc(2026, 11, 9, 12, 0, 0) }

  def stamp(minutes_ago) = (now - (minutes_ago * 60)).strftime("%Y-%m-%dT%H:%M:%SZ")

  def row(boot_ms, caller_name = nil, minutes_ago = 5)
    { "boot_ms" => boot_ms, "caller" => caller_name, "date" => "2026-11-09", "at" => stamp(minutes_ago) }.compact
  end

  def budget(*rows) = Hecks::Adapters::BootBudget.new(entries: ->(_cutoff) { rows }, now: -> { now })

  it "sums the measured boot milliseconds of the window into hours", :aggregate_failures do
    reading = budget(row(1_800_000), row(900_000)).today

    expect(reading.hours).to eq(0.75)
    expect(reading.boots).to eq(2)
  end

  it "prices only the runs that carry a boot time, and counts the others apart", :aggregate_failures do
    unmeasured = { "date" => "2026-11-09", "at" => stamp(5) }
    reading = budget(row(1_000), row(3_000), unmeasured).today

    expect(reading.hours).to eq((4_000 / 3_600_000.0).round(3))
    expect(reading.unmeasured).to eq(1)
  end

  it "adds no hours for a window whose runs have no boot time", :aggregate_failures do
    reading = budget({ "date" => "2026-11-09", "at" => stamp(5) }).today

    expect(reading.hours).to eq(0.0)
    expect(reading.unmeasured).to eq(1)
  end

  it "is a rolling 24 hours from each run's start, not the calendar day", :aggregate_failures do
    yesterday = row(3_600_000, nil, 23 * 60).merge("date" => "2026-11-08")
    reading = budget(yesterday, row(900_000, nil, 25 * 60)).today

    expect(reading.hours).to eq(1.0)
    expect(reading.boots).to eq(1)
  end

  it "leaves out a run with neither a start time nor a boot time" do
    expect(budget({ "date" => "2026-11-09" }).today.boots).to eq(0)
  end

  it "prices a measured run recorded before start times, by its day", :aggregate_failures do
    early = { "boot_ms" => 1_800_000, "date" => "2026-11-09" }
    stale = { "boot_ms" => 1_800_000, "date" => "2026-11-07" }
    reading = budget(early, stale).today

    expect(reading.hours).to eq(0.5)
    expect(reading.boots).to eq(1)
  end

  it "names who booted in the last hour, most first, and leaves out older runs" do
    rows = [row(1, "a"), row(1, "a"), row(1, "b"), row(1, "old", 90), row(1)]

    expect(budget(*rows).today.last_hour).to eq("a" => 2, "b" => 1, "unnamed" => 1)
  end

  it "reads nothing from a record that is not there" do
    reader = Hecks::Adapters::BootBudget.new(now: -> { now })
    allow(Hecks::Adapters::Driving::UsageLog).to receive(:path).and_return("/nonexistent/usage.jsonl")

    expect(reader.today.boots).to eq(0)
  end

  it "says the budget is spent once the measured hours reach it", :aggregate_failures do
    spent = budget(row(3_600_000))

    expect(spent.stop_reason(1.0)).to eq("skipped: boot budget spent: 1.0 of 1.0 hours")
    expect(spent.stop_reason(2.0)).to be_nil
  end
end
