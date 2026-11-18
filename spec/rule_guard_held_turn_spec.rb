# frozen_string_literal: true

require "spec_helper"
require_relative "support/missing_value_guards"

# A guard that tests a missing value with `.value == nil` stops or lets through as intended.
RSpec.describe "A guard on the run that holds the turn" do
  include MissingValueGuards

  let(:guard) { "run.value != nil && ended.value == run.value" }

  it "stops when the run is missing" do
    expect(holds_for_missing?(guard, :run, { ended: { value: 1 } })).to eq([false, false])
  end

  it "lets the run that ended through" do
    expect(holds?(guard, { run: { value: 1 }, ended: { value: 1 } })).to be(true)
  end
end
