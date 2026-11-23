# frozen_string_literal: true

require "spec_helper"
require_relative "support/standup_fixtures"

# Work.standup counts the bugs the zero-bug policy watches: those open, and those finished since the time.
RSpec.describe Hecks::Adapters::Standup do
  include StandupFixtures

  let(:ledger) do
    [bug("open-bug"), bug("done-today", status: "done"), bug("done-last-week", status: "done"),
     record("done-theme", status: "done"), record("plain-c")]
  end

  def bug(key, status: "planned") = record(key, status: status).tap { |entry| entry.category = RollForwardFixtures::Word.new("bug") }

  it "counts the bugs still open" do
    finished
    expect(section(standup(ledger), "Bugs")).to include("open: 1")
  end

  it "counts the bugs finished since the time, and not other work items" do
    finished(["done-today", 2], ["done-theme", 2], ["done-last-week", 30])
    expect(section(standup(ledger), "Bugs")).to include("finished: 1")
  end

  it "says so when the ledger holds no bug" do
    finished
    expect(section(standup, "Bugs")).to eq(["open: 0", "finished: 0"])
  end
end
