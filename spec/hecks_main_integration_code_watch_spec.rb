require "spec_helper"

# A MainIntegration advance is one process; it keeps the code it started with, so it ends once the
# checkout's code has changed instead of dispatching more runs on code that is out of date.
RSpec.describe Hecks::Adapters::MainIntegration::CodeWatch do
  # A fingerprint that answers each value in turn, then the last one.
  def fingerprint_of(*values)
    answers = values.dup
    instance_double(Hecks::Adapters::Driving::Resident::Fingerprint).tap do |fake|
      allow(fake).to receive(:current) { answers.size > 1 ? answers.shift : answers.first }
    end
  end

  it "does not move while the fingerprint stays the same" do
    expect(described_class.new(fingerprint_of(7)).moved?).to be(false)
  end

  it "moves once the fingerprint differs from the one it started with" do
    expect(described_class.new(fingerprint_of(7, 9)).moved?).to be(true)
  end

  it "stays moved when the fingerprint changes back" do
    watch = described_class.new(fingerprint_of(1, 2, 1))
    expect([watch.moved?, watch.moved?]).to eq([true, true])
  end

  it "names the code it started with and the code it found" do
    watch = described_class.new(fingerprint_of(0x1a, 0x2b))
    watch.moved?
    expect(watch.report).to eq("advance restarted: code changed from 0000001a to 0000002b")
  end

  it "takes its fingerprint from the checkout the adapter's code was loaded from" do
    expect(File.file?(File.join(described_class::ROOT, "exe", "hecks"))).to be(true)
  end
end
