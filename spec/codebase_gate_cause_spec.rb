# frozen_string_literal: true

require "spec_helper"
require "hecks/hecks/adapters/codebase/gate"

# A red gate's refusal names the checks that failed, so one cause is one cause in any run.
RSpec.describe Hecks::Adapters::Codebase::Gate do
  # The error a gate run that printed the message ends with.
  def refused(message)
    described_class.named_red { raise Hecks::Adapters::ConsoleCapture::Failure, message }
  rescue Hecks::Adapters::ConsoleCapture::Failure => e
    e
  end

  it "names the stage and the red checks in name order" do
    expect(described_class.cause_of("[gate quick] red: rubocop, comment_style")).to eq("gate-quick-comment_style-rubocop")
  end

  it "leaves out the checks skipped as unchanged" do
    report = "[gate quick] red: rubocop; skipped as unchanged: shape_ledger"
    expect(described_class.cause_of(report)).to eq("gate-quick-rubocop")
  end

  it "names no cause for a report with no red line" do
    expect(described_class.cause_of("could not start the gate")).to be_nil
  end

  it "raises a red gate's failure with its cause as the kind", :aggregate_failures do
    error = refused("out\n[gate quick] red: rubocop")

    expect(error).to be_a(described_class::Red)
    expect(error.kind).to eq("gate-quick-rubocop")
  end

  it "raises a failure naming no red check as it was" do
    expect(refused("boom")).not_to be_a(described_class::Red)
  end
end
