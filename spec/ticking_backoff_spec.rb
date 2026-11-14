require "spec_helper"
require "hecks/hecks/adapters/ticking"

# The schedule the chain of ticks waits by: quick while the checks start, then a ladder whose last
# step repeats, and a beat limit that matches it.
RSpec.describe Hecks::Adapters::Ticking::Backoff do
  subject(:backoff) { described_class.new(quick: 20) }

  it "waits the quick period in the first minute" do
    expect(backoff.delay(30, 0)).to eq(20.0)
  end

  it "then climbs the steps and stays on the last", :aggregate_failures do
    expect([0, 1, 2, 3, 9].map { |slow| backoff.delay(90, slow) }).to eq([60.0, 120.0, 240.0, 240.0, 240.0])
    expect(backoff.cap).to eq(240.0)
  end

  it "round-trips through the text a child is given" do
    expect(described_class.parse(described_class.new(quick: 20, steps: [10, 30]).to_s).steps).to eq([10.0, 30.0])
  end

  it "counts far fewer beats in 30 minutes than a 20 second period" do
    expect(backoff.limit(30)).to be < 30 * 60 / 20 / 4
  end
end
