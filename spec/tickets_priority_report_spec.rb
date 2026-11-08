# frozen_string_literal: true

require "spec_helper"
require_relative "support/priority_report_fixtures"

# Work.priority_report prints the backlog in the order Dispatch starts it, from the same ordering.
RSpec.describe Hecks::Adapters::PriorityReport do
  include PriorityReportFixtures

  it "lists the planned items in the order Dispatch rolls forward with" do
    planned = Hecks::Adapters::Dispatching::WorkItems.new(registry_of(seeded)).planned.map(&:key)
    expect(keys(report) - ["run-1"]).to eq(planned)
  end

  it "lists the started item first" do
    expect(keys(report).first).to eq("run-1")
  end

  it "puts red-* items first among the planned" do
    expect(keys(report)[1]).to eq("red-z")
  end

  it "orders tiers now, next, later, none, then by step then id" do
    expect(keys(report)[2..]).to eq(%w[now-e now-a next-d later-b plain-c])
  end

  it "says which items would start" do
    expect(report.grep(/red-z/).first).to include("would start")
  end
end
