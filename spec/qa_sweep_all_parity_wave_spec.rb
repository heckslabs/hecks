require "hecks"
require "hecks/ports/persistence/plugins/era"
require_relative "support/qa_sweep_all_fixture"

# `bin/qa_sweep --all` — the persistence-parity second wave. One of seven
# sibling files split out of the original `qa_sweep_all_spec.rb` (Phase 2
# of the CI speed effort — see `spec/qa_sweep_all_lifecycle_spec.rb`'s
# own header and `spec/support/qa_sweep_all_fixture.rb` for the full
# context). Split again from `qa_sweep_all_report_and_parity_spec.rb` on
# 2026-09-18 — see `spec/qa_sweep_all_output_capture_spec.rb`'s own
# header for why. Own throwaway database:
# `hecks_qa_sweep_all_parity_wave_spec`.
RSpec.describe "bin/qa_sweep --all", :io do
  include_context "with a qa_sweep_all fixture", "hecks_qa_sweep_all_parity_wave_spec"

  # **The second wave** — `--all` runs the persistence-parity pass itself
  # over every target that came back clean from wave 1 and binds
  # PostgresEra. `pg_one` does; `heki_one` does not, so exactly one
  # wave-2 child runs, as an ordinary `bin/qa_sweep pg_one
  # --persistence-parity`, and its own row joins the report under a
  # `[parity wave]` label. `--no-parity` skips it.
  it "runs persistence parity as a second wave over PostgresEra-bound targets that came back clean" do
    identify_targets!("heki_one" => @target_domain_relpath, "pg_one" => @pg_target_domain_relpath)

    stdout, _stderr, status = run_qa_sweep("--all", "--seeds", "2")

    expect(status.exitstatus).to eq(0)
    expect(stdout).to include("parity wave: Memory vs real PostgresEra for 1 target(s), at most " \
                              "#{QualityControlDials::SWEEP_MAX_PARALLEL} at once: pg_one")
    expect(stdout).to include("clean (3): heki_one, pg_one, pg_one [parity wave]")
    expect(stdout)
      .to match(/^  pg_one: ruby_only,self_consistency \(capabilities: postgres_era,sqlite; deferred: persistence_parity\)$/)
    expect(stdout).to match(/^  pg_one \[parity wave\]: persistence_parity \(capabilities: postgres_era,sqlite\)$/)
    expect(stdout).to match(/^  heki_one: ruby_only,self_consistency \(capabilities: sqlite\)$/)

    stdout, _stderr, status = run_qa_sweep("--all", "--seeds", "2", "--no-parity")
    expect(status.exitstatus).to eq(0)
    expect(stdout).not_to include("parity wave")
    expect(stdout).to include("clean (2): heki_one, pg_one")
  end
end
