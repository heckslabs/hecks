# frozen_string_literal: true

require "spec_helper"
require "hecks/tools/gate_report"

RSpec.describe Hecks::Tools::GateReport do
  let(:plan_class) { Struct.new(:run, :skipped, :notes) }

  def verdict_of(plan, results = {})
    described_class.report("quick", plan, results)
  end

  it "is red when no check ran and none was recorded green", :aggregate_failures do
    expect(verdict_of(plan_class.new([], [], []))).to eq(1)
  end

  it "is green when every planned check passed" do
    check = { "id" => "rubocop" }
    expect(verdict_of(plan_class.new([check], [], []), { "rubocop" => ["", true] })).to eq(0)
  end
end
