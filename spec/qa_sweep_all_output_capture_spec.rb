require "hecks"
require "hecks/ports/persistence/plugins/era"
require_relative "support/qa_sweep_all_fixture"

# `bin/qa_sweep --all` — output capture. One of seven sibling files split
# out of the original `qa_sweep_all_spec.rb` (Phase 2 of the CI speed
# effort — see `spec/qa_sweep_all_lifecycle_spec.rb`'s own header and
# `spec/support/qa_sweep_all_fixture.rb` for the full context). Split
# again from `qa_sweep_all_report_and_parity_spec.rb` on 2026-09-18 — that
# file alone cost 196s (four real end-to-end `bin/qa_sweep` runs in one
# file `parallel_rspec` could never distribute across workers), the
# single longest file in the whole postgres_io_parallel suite. This file
# proves the consolidated report never interleaves concurrent children's
# own output. Own throwaway database: `hecks_qa_sweep_all_output_spec`.
RSpec.describe "bin/qa_sweep --all", :io do
  include_context "with a qa_sweep_all fixture", "hecks_qa_sweep_all_output_spec"

  # A genuine finding, an operational error, and a clean target, all at
  # once — three children writing to three separate temp files the whole
  # time (bin/qa_sweep's own `spawn_sweep_child`), so nothing here is
  # racing anything else's stdout. `found_one` points at
  # `spec/fixtures/qa_sweep_all_found_fixture`, a trivially well-behaved
  # Ruby domain diffed against `spec/fixtures/qa_sweep_all_found_fixture_
  # rust`, a small standalone Rust crate whose compiled binary always
  # answers a fixed mismatch — total and permanent by construction,
  # never depending on what the fuzzer happened to generate or on
  # anything else in this codebase being broken.
  it "captures each child's own output without interleaving, and a real finding outranks a real error" do
    identify_targets!(
      "clean_one"  => @target_domain_relpath,
      "found_one"  => "spec/fixtures/qa_sweep_all_found_fixture",
      "broken_one" => "qa/stress_domains/__qa_sweep_all_spec_does_not_exist__"
    )

    stdout, _stderr, status = run_qa_sweep("--all", "--seeds", "2")

    expect(status.exitstatus).to eq(2)
    expect(stdout).to include("clean (1): clean_one", "OPERATIONAL ERRORS (1)",
                              "-- broken_one (exit 1) --", "FOUND SOMETHING (1)")

    # **The un-interleaved, un-abridged proof** — `found_one`'s own report is
    # the last section this script ever prints, so everything from its
    # own header to the end of output came from one child's own temp
    # file, never touched by `clean_one`/`broken_one`'s own concurrent
    # writes.
    found_report = stdout[/^#{'#' * 72}\n# found_one\n.*\z/m]
    expect(found_report).not_to be_nil
    expect(found_report).to include("target:      found_one", "sweep:       SW-found_one-",
                                    "-- instances --", "-- events --")
    expect(found_report).not_to include("clean_one", "broken_one")

    # **Suspended, not held** — by the ledger's own `SuspendOnSurprise`
    # policy, fired inside the child's `Sweep.Check.Surprised` dispatch
    # against real PostgresEra.
    expect(found_report).to include("target found_one SUSPENDED", "--release --notes")
    runtime = Hecks.boot(@fixture_dir)
    found = QualityControl::Target.find("found_one")
    expect(found.status).to eq("suspended")
    expect(found.reason.to_h[:value]).to include("--release")
    rotation = runtime.query("QualityControl::Target.Rotation").map { |row| row[:reference][:value] }
    expect(rotation).to include("clean_one")
    expect(rotation).not_to include("found_one")
  end
end
