require "spec_helper"
require "hecks/hecks/adapters/codebase/gate"

# What a spec of a failed gate run uses: a gate run that ends red, and the work items left undone.
module GateCauseHelpers
  # Runs the gate to a red verdict naming the checks.
  def red_gate(run, checks)
    gate = Hecks::Adapters::Codebase::Gate
    report = "[gate quick] red: #{checks.join(", ")}\n#{run}"
    allow(gate).to receive(:call).and_raise(gate::Red.new(report, gate.cause_of(report)))
    @hecks.dispatch_flat("Hecks::GateRun.Gate", run: run, stage: "quick")
  end

  # @return [Array<Hash>] the undone work items of the key
  def undone(key)
    out, = Hecks::Adapters::Driving::CliRunner.call(runtime: @hecks, program: "hecks", argv: %w[tickets query work.undone])
    JSON.parse(out).select { |row| row["work"] == key }
  end
end

# A red gate files one finding and one work item per cause, not per run: two runs that fail the same
# checks are one cause, and a cause finished and failing again is planned again.
RSpec.describe "a failed gate run, filed by its cause" do
  include GateCauseHelpers

  before(:all) { @hecks = InMemoryDomain.boot_hecks_in_memory }

  it "plans one work item for two runs that fail the same checks", :aggregate_failures do
    red_gate("cause-run-1", %w[rubocop comment_style])
    red_gate("cause-run-2", %w[comment_style rubocop])

    expect(undone("gate-quick-comment_style-rubocop").size).to eq(1)
    expect(undone("cause-run-1")).to be_empty
  end

  it "titles the work item by its cause" do
    red_gate("cause-run-6", %w[rubocop])

    expect(undone("gate-quick-rubocop").map { |row| row["title"] }).to eq(["gate-quick-rubocop"])
  end

  it "plans a work item of its own for a different cause" do
    red_gate("cause-run-3", %w[shape_ledger])

    expect(undone("gate-quick-shape_ledger").size).to eq(1)
  end

  it "plans a finished cause again with the new run's refusal", :aggregate_failures do
    red_gate("cause-run-4", %w[model_check])
    @hecks.dispatch_flat("Tickets::Work.Finish", work: "gate-quick-model_check")
    red_gate("cause-run-5", %w[model_check])

    expect(undone("gate-quick-model_check").map { |row| row["detail"] }).to match([end_with("cause-run-5")])
  end
end
