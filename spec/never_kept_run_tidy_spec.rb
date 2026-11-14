# frozen_string_literal: true

require "spec_helper"

# `Tidy` waits out a kept run's `review_wait` with the guard `kept_at + review_wait <= now`. A run
# no review has kept holds neither, and the guard must let it through. It once tested them with
# `nil?`, which is false for a missing value in a rule, so the guard reached the addition and
# every reap refused every such run: "addition expects a number, got nil". 57 of the 58 finished
# runs of the owner's ledger were of this kind, and none was tidied for nearly three hours.
RSpec.describe "The Tidy guard on a run's kept time and wait" do
  let(:evaluator) { Hecks::Bluebook::Expression::Evaluator }
  let(:now) { { value: 10_000 } }

  let(:guard) do
    hecks = boot_hecks_in_memory
    command = hecks.registry.bluebook("Hecks").aggregate("AgentRun").commands.find { |held| held.hecks_name == "Tidy" }
    command.givens.find { |rule| rule.canonical.include?("review_wait") }
  end

  def allows?(kept_at:, review_wait:)
    evaluator.call_rule(guard, { kept_at: kept_at, review_wait: review_wait, now: now })
  end

  it "lets a run no review has kept through, whether its fields are missing or empty", :aggregate_failures do
    expect(allows?(kept_at: nil, review_wait: nil)).to be(true)
    expect(allows?(kept_at: { value: nil }, review_wait: { value: nil })).to be(true)
  end

  it "lets a run through that has a kept time and no wait" do
    expect(allows?(kept_at: { value: 0 }, review_wait: { value: nil })).to be(true)
  end

  it "holds a kept run until its wait has passed", :aggregate_failures do
    expect(allows?(kept_at: { value: 9_000 }, review_wait: { value: 3_600 })).to be(false)
    expect(allows?(kept_at: { value: 9_000 }, review_wait: { value: 1_000 })).to be(true)
  end

  it "lets a released run through, whose kept time is zero" do
    expect(allows?(kept_at: { value: 0 }, review_wait: { value: 3_600 })).to be(true)
  end
end
