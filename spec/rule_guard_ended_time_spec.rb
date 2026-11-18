# frozen_string_literal: true

require "spec_helper"
require_relative "support/missing_value_guards"

# A guard that tests a missing value with `.value == nil` stops or lets through as intended.
RSpec.describe "A guard on an ended time" do
  include MissingValueGuards

  let(:guard) { "ended_at.value == nil || ended_at.value == 0" }

  it "lets a missing or zero time through", :aggregate_failures do
    expect(holds_for_missing?(guard, :ended_at)).to eq([true, true])
    expect(holds?(guard, { ended_at: { value: 0 } })).to be(true)
  end

  it "stops a time that is set" do
    expect(holds?(guard, { ended_at: { value: 9 } })).to be(false)
  end
end
