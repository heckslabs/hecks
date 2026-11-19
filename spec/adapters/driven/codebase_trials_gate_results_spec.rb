# frozen_string_literal: true

require "spec_helper"
require "stringio"
require "hecks/hecks/adapters/codebase/trials"
require "hecks/tools/gate_report"

# Prints a verdict as the gate's own report does, so the reading is pinned to that format.
module TrialsGateReportHelpers
  # What the gate's report prints for a verdict.
  def printed(verdict, ran, skipped = [])
    saved = $stdout
    $stdout = StringIO.new
    skipped.each { |id| Hecks::Tools::GateReport.print_skipped("quick", { "id" => id }, "now") }
    Hecks::Tools::GateReport.summary("quick", verdict, ran.map { |id| { "id" => id } }, [], 0)
    $stdout.string
  ensure
    $stdout = saved
  end
end

RSpec.describe Hecks::Adapters::Codebase::Trials::GateResults do
  include TrialsGateReportHelpers

  it "takes every check a green verdict names as passed" do
    expect(described_class.call(printed("green", %w[rubocop shape_ledger]), [])).to eq("rubocop" => true, "shape_ledger" => true)
  end

  it "takes the planned checks a red verdict leaves out as passed, and skipped ones as no trial" do
    text = printed("red", %w[rubocop], %w[shape_ledger])
    results = described_class.call(text, %w[rubocop comment_style shape_ledger])
    expect(results).to eq("rubocop" => false, "comment_style" => true)
  end

  it "finds no trial in a text without a verdict" do
    expect(described_class.call("ran", %w[rubocop])).to eq({})
  end
end
