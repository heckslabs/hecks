# frozen_string_literal: true

require "spec_helper"
require_relative "support/missing_value_guards"

# A reap turn is freed only by the reap that holds it. Its guard tests a missing run with
# `.value != nil`, so a turn no run holds is never freed by an ended reap.
RSpec.describe "The ReapTurn guard on the run that holds the turn" do
  include MissingValueGuards

  let(:free) do
    turn = MissingValueGuards.bluebook("lib/hecks/hecks", "Hecks").aggregate("ReapTurn")
    given_of(turn.commands.find { |held| held.hecks_name == "Free" }, "run.value != nil")
  end

  def frees?(run, ended)
    Hecks::Bluebook::Expression::Evaluator.call_rule(free, { run: run }, { ended: ended })
  end

  it "stops when no run holds the turn" do
    expect(MissingValueGuards::MISSING.map { |run| frees?(run, { value: "r1" }) }).to eq([false, false])
  end

  it "lets the run that holds the turn free it, and no other", :aggregate_failures do
    expect(frees?({ value: "r1" }, { value: "r1" })).to be(true)
    expect(frees?({ value: "r1" }, { value: "r2" })).to be(false)
  end
end
