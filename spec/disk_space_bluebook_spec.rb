require "spec_helper"
require_relative "support/disk_space_rows"

# The DiskSpace level, read from the `Verdict` rows with scratch values, and the lines it reads.
RSpec.describe "the DiskSpace level", :aggregate_failures do
  include DiskSpaceRows

  it "declares the four aggregates" do
    names = %w[Reading Level Relief Cache]

    expect(names.map { |name| hecks_bluebook.aggregate(name).hecks_name }).to eq(names)
  end

  it "defaults the lines to the owner's: rising at 60 GB or 80%, high at 30 GB or 90%" do
    expect(lines).to eq("rising_free_gb" => 60, "rising_used_percent" => 80, "high_free_gb" => 30, "high_used_percent" => 90)
  end

  it "is calm above both lines" do
    expect(level(61, 79)).to eq("calm")
  end

  it "is rising at each rising line, and high at each high line" do
    expect([level(59, 10), level(100, 80), level(29, 10), level(100, 90)]).to eq(%w[rising rising high high])
  end

  it "takes the worse of free gigabytes and used percent" do
    expect([level(20, 50), level(100, 85), level(40, 95), level(45, 85)]).to eq(%w[high rising high rising])
  end

  it "moves the lines with scratch values" do
    expect(level(100, 50, lines.merge("high_free_gb" => 120))).to eq("high")
  end
end
