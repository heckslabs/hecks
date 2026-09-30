require "hecks"
require "hecks/ports/persistence/plugins/era"
require_relative "support/qa_sweep_all_fixture"

# `qa_sweep --all`: the persistence-parity second wave.
# Own throwaway database: `hecks_qa_sweep_all_parity_wave_spec`.
RSpec.describe "qa_sweep --all", :io do
  include_context "with a qa_sweep_all fixture", "hecks_qa_sweep_all_parity_wave_spec"

  # Wave 2 runs persistence parity as its own `qa_sweep pg_one --persistence-parity` child
  # for each clean PostgresEra-bound target; `heki_one` is not bound, so only one child runs.
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
