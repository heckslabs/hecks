# frozen_string_literal: true

require "spec_helper"
require "hecks/hecks/adapters/codebase/gate"

RSpec.describe Hecks::Adapters::Codebase::Gate do
  it "reads the expected and recorded counts from the gate's printed line", :aggregate_failures do
    counts = described_class.counts_of("[gate quick] green: a\ngate-counts expected=5 recorded=5")
    expect(counts).to eq(expected: { value: "5" }, recorded: { value: "5" })
  end

  it "claims zero when the gate printed no counts, so the verdict refuses green", :aggregate_failures do
    counts = described_class.counts_of("[gate quick] green: a")
    expect(counts).to eq(expected: { value: "0" }, recorded: { value: "0" })
  end
end
