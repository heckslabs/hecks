require "hecks"
require "hecks/ports/persistence/plugins/era"
require_relative "support/qa_sweep_all_fixture"

# `bin/qa_sweep --all` — the `dry_runs` comparison surface. One of seven
# sibling files split out of the original `qa_sweep_all_spec.rb` (Phase 2
# of the CI speed effort — see `spec/qa_sweep_all_lifecycle_spec.rb`'s
# own header and `spec/support/qa_sweep_all_fixture.rb` for the full
# context). Split again from `qa_sweep_all_report_and_parity_spec.rb` on
# 2026-09-18 — see `spec/qa_sweep_all_output_capture_spec.rb`'s own
# header for why. Own throwaway database:
# `hecks_qa_sweep_all_dry_run_spec`.
RSpec.describe "bin/qa_sweep --all", :io do
  include_context "with a qa_sweep_all fixture", "hecks_qa_sweep_all_dry_run_spec"

  # **The `dry_runs` comparison surface finds something on its own** — item 5
  # of the detection plan. `--dry-run 1` turns every generated command
  # step into a `{"dry_run": …}` step, so the Ruby side of
  # `spec/fixtures/qa_sweep_all_dry_run_fixture` produces no instances,
  # events or refusals — exactly what the fixture crate's own feature
  # answers — and the two sides differ on `dry_runs` alone.
  # `--self-consistency false` keeps the Rust rehydration door out of
  # it: this example is about one surface, proven in isolation.
  it "finds a dry_runs-only divergence, with every other surface agreeing" do
    identify_targets!("dry_run_one" => "spec/fixtures/qa_sweep_all_dry_run_fixture")

    stdout, _stderr, status = run_qa_sweep("dry_run_one", "--seeds", "2", "--dry-run", "1", "--self-consistency", "false")

    expect(status.exitstatus).to eq(2)
    expect(stdout).to include("resolved modes: differential,properties_in_differential,structural_skip_report " \
                              "(capabilities=rust,sqlite)")
    expect(stdout).to include("seed 1: SURPRISED (differential)")
    expect(stdout).to include("subject:     [differential] qa_sweep_all_dry_run_fixture fuzz seed 1")
    expect(stdout).to include("observation: diverged on: dry_runs", "-- dry_runs --")
    expect(stdout).not_to include("-- instances --", "-- events --", "-- refusals --")
    expect(stdout).to include("__qa_sweep_all_spec_phantom_dry_run__")
  end
end
