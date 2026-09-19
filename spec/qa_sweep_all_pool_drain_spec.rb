require "hecks"
require "hecks/ports/persistence/plugins/era"
require_relative "support/qa_sweep_all_fixture"

# `bin/qa_sweep --all` — THE POOL DRAINING FAST CHILDREN. Split out of
# `qa_sweep_all_concurrency_spec.rb`, which was the slowest file in the
# Postgres shards (165s for two examples) and so the floor under any shard's
# wall-clock: a shard cannot finish sooner than its longest single file.
# This file's own throwaway database is `hecks_qa_sweep_all_pool_drain_spec`,
# unique so it never races a sibling file's scratch resources.
RSpec.describe "bin/qa_sweep --all", :io do
  include_context "with a qa_sweep_all fixture", "hecks_qa_sweep_all_pool_drain_spec"

  # THE FAILURE MODE THAT PROMPTED THE POOL BOUND EXAMPLE'S OWN COMMENT
  # (qa_sweep_all_concurrency_spec.rb), EXERCISED DIRECTLY — not just the
  # happy path where children happen to take a couple of seconds each.
  # Every target here finishes about as fast as a real OS process CAN, so
  # several children exit within the SAME `Process.wait2(-1)` polling
  # window inside `run_pool` (bin/qa_sweep) — the exact "a spawned child
  # exits very early/fast" shape a bounded pool's bookkeeping has to survive.
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
