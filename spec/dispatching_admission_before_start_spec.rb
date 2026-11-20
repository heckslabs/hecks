# frozen_string_literal: true

require "spec_helper"
require_relative "support/admission_before_start"

# The probe of 2026-11-20 06:29-06:44: the fill planned on one beat, started the work item, and the
# start's own check read a second beat short and yielded it. A fill now asks admission just before
# each start; a refusal starts nothing, and the start's check keeps the fill's ruling.
RSpec.describe Hecks::Adapters::Dispatching, "#choose" do
  include AdmissionBeforeStart

  let(:short) { "skipped: signalbox: only an urgent coder is admitted while pressure is short" }

  before { described_class::AdmissionGrants.clear! }

  it "starts nothing admission refuses just before the start, so no WorkStarted stands" do
    fill(short)
    expect(calls).not_to include("Work.start!")
  end

  it "says the refused item waits on admission", :aggregate_failures do
    text = fill(short)
    expect(text).to include("sim-properties-independent waits: #{short}")
    expect(text).to include("this fill: 0 started, 0 yielded, 1 waiting on admission of 1")
  end

  it "starts an item admission admits just before the start, once" do
    fill(nil)
    expect(calls.count("Work.start!")).to eq(1)
  end

  it "grants an expedited item the plan's ruling, which the start's check keeps" do
    fill(short, [item_of("hotfix", "expedite")])
    expect(described_class::AdmissionGrants.take?("hotfix", within: 60)).to be(true)
  end
end
