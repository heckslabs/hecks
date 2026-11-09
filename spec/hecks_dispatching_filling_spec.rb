require "spec_helper"
require "hecks/hecks/adapters/dispatching"

# A roll that began while a confirmed filling is under way would start the same work twice.
RSpec.describe Hecks::Adapters::Dispatching::Filling do
  it "marks a confirmed filling, and only while it runs", :aggregate_failures do
    inside = described_class.during(true) { described_class.running? }

    expect(inside).to be(true)
    expect(described_class.running?).to be(false)
  end

  it "does not mark a dry run" do
    expect(described_class.during(false) { described_class.running? }).to be(false)
  end

  it "keeps the mark of the filling it is nested in" do
    expect(described_class.during(true) { described_class.during(false) { described_class.running? } }).to be(true)
  end
end
