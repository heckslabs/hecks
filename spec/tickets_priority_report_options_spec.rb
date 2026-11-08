# frozen_string_literal: true

require "spec_helper"
require_relative "support/priority_report_fixtures"

# The reasons, the header and the options of Work.priority_report.
RSpec.describe Hecks::Adapters::PriorityReport do
  include PriorityReportFixtures

  def preview = Hecks::Adapters::Dispatching.new(registry: registry_of(seeded), settings: settings).preview[:text]

  it "gives the reason Dispatch.preview gives for a waiting item", :aggregate_failures do
    expect(preview).to include("now-e skipped: cap 2 reached")
    expect(report.grep(/now-e/).first).to include("cap 2 reached")
  end

  it "says an overlap and the item it overlaps" do
    entries = [record("run", status: "started", area: "lib/a"), record("x", area: "lib/a/b")]
    expect(report(entries, cap: 5).grep(/\sx\s/).first).to include("overlaps run")
  end

  it "heads the list with counts per tier and started of cap" do
    expect(report.first).to eq("red 1, now 2, next 1, later 1, none 2; started 1 of cap 2")
  end

  it "limits to a tier" do
    expect(keys(report(tier: { value: "now" }))).to eq(%w[now-e now-a])
  end

  it "limits the number of lines" do
    expect(report(limit: { value: 2 }).size).to eq(3)
  end

  it "fits a width" do
    expect(report(width: { value: 60 }).map(&:length).max).to be <= 60
  end
end
