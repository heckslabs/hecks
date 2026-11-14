# frozen_string_literal: true

require "spec_helper"
require_relative "support/standup_fixtures"

# Work.standup says what starts next from the priority report's ordering, how loaded the machine
# is, and that the blocked work items are not listed yet.
RSpec.describe Hecks::Adapters::Standup do
  include StandupFixtures

  before { finished }

  it "lists the next three planned work items in the order Dispatch starts them" do
    expect(section(standup, "Starts next").map { |line| line[/\d\. ([\w-]+)/, 1] }).to eq(%w[red-z now-e now-a])
  end

  it "says why each of the next three starts or waits" do
    expect(section(standup, "Starts next")).to all(include("would start").or(include("waits: ")))
  end

  it "says the reason the priority report gives for a waiting work item" do
    entries = seeded.reject { |entry| entry.work == "red-z" }
    expect(section(standup(entries), "Starts next").last).to include("waits: cap 2 reached")
  end

  it "says so when nothing is planned" do
    expect(section(standup([record("run-1", status: "started")]), "Starts next")).to eq(["nothing is planned"])
  end

  it "says the load against the most allowed, and the memory" do
    expect(section(standup, "Load and memory"))
      .to eq(["load 3.2 of 4.0 allowed, CPU 60.1% idle, swap 12.5% used, compressor 4.25 GB, 2.3 GB free"])
  end

  it "leaves out a gauge the machine does not give" do
    expect(section(standup(gauges: { load: 1.0 }), "Load and memory")).to eq(["load 1.0 of 4.0 allowed"])
  end

  it "says the blocked work items are not listed yet" do
    expect(section(standup, "Blocked or old")).to eq(["not listed in this standup yet"])
  end
end
