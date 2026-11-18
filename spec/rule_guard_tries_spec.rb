# frozen_string_literal: true

require "spec_helper"
require_relative "support/missing_value_guards"

# A guard that tests a missing value with `.value == nil` stops or lets through as intended.
RSpec.describe "A guard on a verdict's tries" do
  include MissingValueGuards

  let(:left) { "tries.value == nil || tries.value < 3" }
  let(:spent) { "tries.value != nil && tries.value >= 3" }

  it "has tries left when they are missing", :aggregate_failures do
    expect(holds_for_missing?(left, :tries)).to eq([true, true])
    expect(holds_for_missing?(spent, :tries)).to eq([false, false])
  end

  it "has none left at three", :aggregate_failures do
    expect(holds?(left, { tries: { value: 3 } })).to be(false)
    expect(holds?(spent, { tries: { value: 3 } })).to be(true)
  end
end
