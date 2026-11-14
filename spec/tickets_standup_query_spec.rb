# frozen_string_literal: true

require "spec_helper"
require_relative "support/standup_fixtures"

# Work.standup is a query: it refuses a time it cannot read, writes nothing, and the Tickets
# bluebook declares it with the window it covers and the port that answers it.
RSpec.describe Hecks::Adapters::Standup do
  include StandupFixtures

  def tickets = @tickets ||= boot_hecks_in_memory(File.expand_path("../lib/hecks/tickets/bluebook", __dir__))

  def work = tickets.registry.bluebook("Tickets").aggregates.find { |aggregate| aggregate.hecks_name == "Work" }

  it "refuses a time that is not one" do
    finished
    expect { standup(since: { value: "yesterday" }) }
      .to raise_error(Hecks::Adapters::ConsoleCapture::Failure, /not an ISO 8601 time/)
  end

  it "writes nothing to the tap" do
    finished(["run-1", 2])
    expect { standup }.not_to(change { File.read(tap) })
  end

  it "reads its window from the bluebook's row" do
    window = described_class::Window.new(work, StandupFixtures::NOON)
    expect([StandupFixtures::NOON - window.since(nil), window.upcoming]).to eq([24 * 3600, 3])
  end

  def booted_text
    finished
    stand_ins = settings.merge(tap: tap, readings: -> { StandupFixtures::GAUGES })
    described_class.new(registry: tickets.registry, settings: stand_ins).standup[:text]
  end

  it "answers over the booted Tickets bluebook with the four sections" do
    expect(booted_text.scan(/^\S.*:$/).size).to eq(4)
  end
end
