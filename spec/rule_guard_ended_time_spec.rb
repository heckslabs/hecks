# frozen_string_literal: true

require "spec_helper"
require_relative "support/missing_value_guards"

# A watch's guards test a missing end time with `.value == nil`: a watch that has not ended,
# whose time is missing or zero, may lapse or give up, and an ended one may not.
RSpec.describe "The Watcher guards on a missing end time" do
  include MissingValueGuards

  let(:watcher) { MissingValueGuards.bluebook("lib/hecks/agents", "Agents").aggregate("Watcher") }

  def holds_for?(command, ended_at)
    held = watcher.commands.find { |each| each.hecks_name == command }
    holds?(given_of(held, "ended_at"), { ended_at: ended_at })
  end

  it "lets a watch whose end time is missing or zero through", :aggregate_failures do
    expect(%w[Lapse GiveUp].map { |command| holds_for?(command, nil) }).to eq([true, true])
    expect(%w[Lapse GiveUp].map { |command| holds_for?(command, { value: nil }) }).to eq([true, true])
    expect(holds_for?("Lapse", { value: 0 })).to be(true)
  end

  it "stops a watch that has ended" do
    expect(%w[Lapse GiveUp].map { |command| holds_for?(command, { value: 9 }) }).to eq([false, false])
  end
end
