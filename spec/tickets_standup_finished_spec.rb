# frozen_string_literal: true

require "spec_helper"
require_relative "support/standup_fixtures"

# Work.standup says what finished since a time, read from the event tap.
RSpec.describe Hecks::Adapters::Standup do
  include StandupFixtures

  it "lists a work item finished since the time, with its title" do
    finished(["run-1", 2])
    expect(section(standup(since: { value: "2026-11-14T09:00:00Z" }), "Finished")).to eq(["run-1: run-1"])
  end

  it "leaves out a work item finished before the time" do
    finished(["later-b", 5], ["run-1", 2])
    expect(section(standup(since: { value: "2026-11-14T09:00:00Z" }), "Finished")).to eq(["run-1: run-1"])
  end

  it "covers the last 24 hours when no time is given" do
    finished(["later-b", 30], ["now-a", 23], ["run-1", 2])
    expect(section(standup, "Finished")).to eq(["now-a: now-a", "run-1: run-1"])
  end

  it "says the time it covers from" do
    finished(["run-1", 2])
    expect(standup).to include("Finished since 2026-11-13T12:00:00Z")
  end

  it "lists a work item finished twice once" do
    finished(["run-1", 3], ["run-1", 2])
    expect(section(standup, "Finished").size).to eq(1)
  end

  it "says so when nothing finished" do
    finished
    expect(section(standup, "Finished")).to eq(["nothing"])
  end
end
