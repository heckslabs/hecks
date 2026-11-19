# frozen_string_literal: true

require "spec_helper"
require_relative "support/missing_value_guards"

# A verdict's guards test missing tries with `.value == nil`: a verdict never redelivered has
# tries left, and is abandoned only once its tries reach three.
RSpec.describe "The Verdict guards on its tries" do
  include MissingValueGuards

  let(:verdict) { MissingValueGuards.bluebook("lib/hecks/agents", "Agents").aggregate("Verdict") }

  def holds_for?(command, phrase, tries)
    held = verdict.commands.find { |each| each.hecks_name == command }
    holds?(given_of(held, phrase), { tries: tries })
  end

  it "has tries left, and none spent, when they are missing", :aggregate_failures do
    expect(MissingValueGuards::MISSING.map { |tries| holds_for?("Redeliver", "tries.value == nil", tries) }).to eq([true, true])
    expect(MissingValueGuards::MISSING.map { |tries| holds_for?("Abandon", "tries.value != nil", tries) }).to eq([false, false])
  end

  it "has none left at three", :aggregate_failures do
    expect(holds_for?("Redeliver", "tries.value == nil", { value: 3 })).to be(false)
    expect(holds_for?("Abandon", "tries.value != nil", { value: 3 })).to be(true)
  end
end
