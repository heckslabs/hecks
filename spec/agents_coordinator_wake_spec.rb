require "spec_helper"
require_relative "support/escalation_boot"

# An exception wakes the coordinator through an escalation raised once per key.
RSpec.describe "the escalation that wakes the coordinator" do
  include EscalationBoot

  before { boot }

  it "wakes the coordinator for an exception" do
    raise_for("stall-train-pr-red-9")
    expect(woken.size).to eq(1)
  end

  it "wakes it once per key" do
    raise_twice("stall-train-pr-red-9")
    expect(woken.size).to eq(1)
  end

  it "wakes it again for another stall" do
    %w[stall-a-1 stall-b-2].each { |key| raise_for(key) }
    expect(woken.size).to eq(2)
  end
end
