require "hecks"
require "hecks/ports/persistence/plugins/era"
require_relative "support/qa_sweep_all_fixture"

# `qa_sweep --all`: the pool draining fast children.
# Own throwaway database `hecks_qa_sweep_all_pool_drain_spec`, so it never races a sibling file.
RSpec.describe "qa_sweep --all", :io do
  include_context "with a qa_sweep_all fixture", "hecks_qa_sweep_all_pool_drain_spec"

  # Every target finishes almost instantly, so several children exit within the same
  # `Process.wait2(-1)` window inside `run_pool`, which the pool's bookkeeping must survive.
  # Identifies three pools' worth of targets that all point at the fixture domain; answers their
  # references. The pool size is read after the boot, which is what loads `QualityControlDials`:
  # read before it, the constant exists only when an earlier spec of the same process booted it.
  def identify_fast_targets!
    Hecks.boot(@fixture_dir)
    (1..(QualityControlDials::SWEEP_MAX_PARALLEL * 3)).map do |n|
      QualityControl::Target.identify!(reference: { value: "fast_#{n}" }, path: { value: @target_domain_relpath })
      "fast_#{n}"
    end
  end

  it "drains a pool of near-instantly-exiting children without stalling", :aggregate_failures do
    targets = identify_fast_targets!
    stdout, stderr, status = run_qa_sweep("--all", "--seeds", "1", "--steps", "1")

    expect(status.exitstatus).to eq(0), "expected a clean --all, got:\nSTDOUT:\n#{stdout}\nSTDERR:\n#{stderr}"
    expect(stdout).to include("clean (#{targets.size})")
  end
end
