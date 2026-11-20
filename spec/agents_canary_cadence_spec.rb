require "spec_helper"
require_relative "support/canary_helpers"

# A known-bad patch is planted round robin, one per window: the canary cadence opens with the first
# canary and a sweep's tick inside the window plants nothing.
RSpec.describe "the Agents canary cadence" do
  include CanaryHelpers

  before { boot_agents }

  it "plants nothing before a canary is added" do
    expect(Hecks::Agents::CanaryCadence.all).to be_empty
  end

  it "plants the canary planted least recently, one per window" do
    %w[c1 c2].each { |name| add_canary(name) }
    [CanaryHelpers::DAY, CanaryHelpers::DAY + 60, 2 * CanaryHelpers::DAY].each { |now| tick(now) }
    expect([canary("c1").plants.value, canary("c2").plants.value]).to eq([1, 1])
  end

  it "holds the cadence's Setting row to the one-day window" do
    expect(cadence_setting("canary_every_seconds")[:value]).to eq(CanaryHelpers::DAY)
  end
end
