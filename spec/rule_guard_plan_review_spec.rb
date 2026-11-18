# frozen_string_literal: true

require "spec_helper"
require_relative "support/missing_value_guards"

# A plan review's guards test a missing verdict, end time or ask count with `.value == nil`, so a
# review that holds none of them is let through, and one that holds them is stopped.
RSpec.describe "The PlanReview guards on a missing verdict, end time and ask count" do
  include MissingValueGuards

  let(:review) { MissingValueGuards.bluebook("lib/hecks/agents", "Agents").aggregate("PlanReview") }

  def guard(command, phrase)
    given_of(review.commands.find { |held| held.hecks_name == command }, phrase)
  end

  def holds_on_missing(command, phrase, field)
    MissingValueGuards::MISSING.map { |value| holds?(guard(command, phrase), { field => value }) }
  end

  it "lets a review with no verdict, no end time and no asks through", :aggregate_failures do
    expect(holds_on_missing("Answer", "ended_at", :ended_at)).to eq([true, true])
    expect(holds_on_missing("Unstart", "verdict.value", :verdict)).to eq([true, true])
    expect(holds_on_missing("Reask", "ended_at", :ended_at)).to eq([true, true])
    expect(holds_on_missing("Reask", "asks.value == nil", :asks)).to eq([true, true])
  end

  it "stops a review that has a verdict, an end time or an ask", :aggregate_failures do
    expect(holds?(guard("Unstart", "verdict.value"), { verdict: { value: "sound" } })).to be(false)
    expect(holds?(guard("Lapse", "ended_at"), { ended_at: { value: 9 } })).to be(false)
    expect(holds?(guard("Reask", "asks.value == nil"), { asks: { value: 1 } })).to be(false)
  end

  it "asks again already only when an ask is held", :aggregate_failures do
    expect(holds_on_missing("Lapse", "asks.value != nil", :asks)).to eq([false, false])
    expect(holds?(guard("Lapse", "asks.value != nil"), { asks: { value: 1 } })).to be(true)
  end
end
