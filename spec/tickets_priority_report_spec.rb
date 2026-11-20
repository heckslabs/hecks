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

  it "says a planned item waits on a work item that has not landed, as the fill does" do
    held = record("held-w", priority: "now").tap { |entry| entry.waits_on = [RollForwardFixtures::Word.new("run-1")] }
    expect(report(seeded + [held]).grep(/held-w/).first).to include("waits on run-1")
  end

  it "says a planned item would start when the work item it waits on is done, though no landing names it" do
    held = record("held-w", priority: "now").tap { |entry| entry.waits_on = [RollForwardFixtures::Word.new("old-1")] }
    lines = report(seeded + [held, record("old-1", status: "done")], cap: 9)
    expect(lines.grep(/held-w/).first).to include("would start")
  end
end
