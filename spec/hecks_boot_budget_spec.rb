require "spec_helper"
require "hecks/hecks/adapters/dispatching"

# The launcher's boot budget: the hours of boots the usage record holds for today, and who
# booted in the last hour. The usage record is a stand-in, so the live record is never read.
RSpec.describe "the boot budget" do
  let(:now) { Time.utc(2026, 11, 9, 12, 0, 0) }

  def row(boot_ms, caller_name = nil, minutes_ago = 5)
    { "boot_ms" => boot_ms, "caller" => caller_name, "date" => "2026-11-09",
      "at" => (now - (minutes_ago * 60)).strftime("%Y-%m-%dT%H:%M:%SZ") }.compact
  end

  def budget(*rows) = Hecks::Adapters::BootBudget.new(entries: ->(_date) { rows }, now: -> { now })

  it "sums the boot milliseconds of today into hours", :aggregate_failures do
    reading = budget(row(1_800_000), row(900_000)).today

    expect(reading.hours).to eq(0.75)
    expect(reading.boots).to eq(2)
  end

  it "counts a run with no boot time at the median, and says so", :aggregate_failures do
    reading = budget(row(1_000), row(3_000), { "date" => "2026-11-09" }).today

    expect(reading.hours).to eq(((1_000 + 3_000 + 3_000) / 3_600_000.0).round(3))
    expect(reading.unmeasured).to eq(1)
  end

  it "leaves unmeasured runs out when none of today's has a boot time", :aggregate_failures do
    reading = budget({ "date" => "2026-11-09" }).today

    expect(reading.hours).to eq(0.0)
    expect(reading.unmeasured).to eq(1)
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

  it "says the budget is spent once the hours reach it", :aggregate_failures do
    spent = budget(row(3_600_000))

    expect(spent.stop_reason(1.0)).to eq("skipped: boot budget spent: 1.0 of 1.0 hours")
    expect(spent.stop_reason(2.0)).to be_nil
  end
end
