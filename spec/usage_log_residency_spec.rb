require "spec_helper"
require "time"

# `hecks usage` says how the runs met the resident: how many of each outcome and how long their
# boots took, the share served, why the resident refused, and who booted in the last hour. Lines
# written before the field existed still count, under `unrecorded`.
RSpec.describe Hecks::Adapters::Driving::UsageLog::Residency do
  let(:now) { Time.utc(2026, 11, 9, 12, 0, 0) }
  let(:runs) do
    [{ "resident" => "served", "boot_ms" => 70, "caller" => "a", "at" => "2026-11-09T11:30:00Z" },
     { "resident" => "served", "boot_ms" => 90, "caller" => "a", "at" => "2026-11-09T11:59:00Z" },
     { "resident" => "refused:env", "boot_ms" => 1500, "caller" => "b", "at" => "2026-11-09T10:00:00Z" },
     { "resident" => "none", "boot_ms" => 1300 },
     { "resolved" => "work.undone" }]
  end
  let(:text) { described_class.lines(runs, now: now).join("\n") }

  it "counts the runs of each outcome with the median boot of each", :aggregate_failures do
    expect(text).to include("2  served", "90 ms median boot", "1  refused:env", "1500 ms median boot")
    expect(text).to include("1  unrecorded")
  end

  it "says what share of the recorded runs a resident served" do
    expect(text).to include("served: 2 of 4 recorded runs (50%)")
  end

  it "ranks the reasons a resident refused" do
    expect(text).to include("refused because:", "1  env")
  end

  it "counts the last hour's boots per caller, leaving out the runs with no time", :aggregate_failures do
    expect(text).to include("boots in the last hour, by caller:", "2  a")
    expect(text).not_to match(/1\s+b$/)
  end

  it "prints no section when no run has an outcome" do
    expect(described_class.lines([{ "resolved" => "work.undone" }], now: now)).to eq([])
  end

  it "reads the outcome this process was told", :aggregate_failures do
    ENV["HECKS_RESIDENT_OUTCOME"] = "refused:busy"
    expect(described_class.outcome).to eq("refused:busy")
    expect(described_class.served?).to be(false)
  ensure
    ENV.delete("HECKS_RESIDENT_OUTCOME")
  end
end
