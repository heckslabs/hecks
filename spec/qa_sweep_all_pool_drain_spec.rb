require "hecks"
require "hecks/ports/persistence/plugins/era"
require_relative "support/qa_sweep_all_fixture"

# `bin/qa_sweep --all`: the pool draining fast children.
# Own throwaway database `hecks_qa_sweep_all_pool_drain_spec`, so it never races a sibling file.
RSpec.describe "bin/qa_sweep --all", :io do
  include_context "with a qa_sweep_all fixture", "hecks_qa_sweep_all_pool_drain_spec"

  # Every target finishes almost instantly, so several children exit within the same
  # `Process.wait2(-1)` window inside `run_pool`, which the pool's bookkeeping must survive.
  it "drains a pool of near-instantly-exiting children without stalling" do
    Hecks.boot(@fixture_dir)
    max_parallel = QualityControlDials::SWEEP_MAX_PARALLEL
    targets = (1..(max_parallel * 3)).to_h { |n| ["fast_#{n}", @target_domain_relpath] }
    targets.each { |reference, path| QualityControl::Target.identify!(reference: { value: reference }, path: { value: path }) }

    stdout, stderr, status = run_qa_sweep("--all", "--seeds", "1", "--steps", "1")

    expect(status.exitstatus).to eq(0), "expected a clean --all, got:\nSTDOUT:\n#{stdout}\nSTDERR:\n#{stderr}"
    expect(stdout).to include("clean (#{targets.size})")
  end
end
