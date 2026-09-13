require "hecks"
require "hecks/ports/persistence/plugins/era"
require_relative "support/qa_sweep_all_fixture"

# `bin/qa_sweep --all` — REPORT FORMATTING AND PERSISTENCE PARITY. Last
# of four sibling files split out of the original `qa_sweep_all_spec.rb`
# (Phase 2 of the CI speed effort — see `spec/qa_sweep_all_lifecycle_
# spec.rb`'s own header and `spec/support/qa_sweep_all_fixture.rb` for
# the full context). This file proves the consolidated report never
# interleaves concurrent children's own output, the persistence-parity
# second wave, and the `dry_runs`-only divergence surface. Own throwaway
# database: `hecks_qa_sweep_all_report_spec`.
RSpec.describe "bin/qa_sweep --all", :io do
  include_context "with a qa_sweep_all fixture", "hecks_qa_sweep_all_report_spec"

  # A GENUINE FINDING, AN OPERATIONAL ERROR, AND A CLEAN TARGET, ALL AT
  # ONCE — three children writing to three SEPARATE temp files the whole
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

    # THE UN-INTERLEAVED, UN-ABRIDGED PROOF — `found_one`'s own report is
    # the LAST section this script ever prints, so everything from its
    # own header to the end of output came from ONE child's own temp
    # file, never touched by `clean_one`/`broken_one`'s own concurrent
    # writes.
    found_report = stdout[/^#{'#' * 72}\n# found_one\n.*\z/m]
    expect(found_report).not_to be_nil
    expect(found_report).to include("target:      found_one", "sweep:       SW-found_one-",
                                    "-- instances --", "-- events --")
    expect(found_report).not_to include("clean_one", "broken_one")

    # SUSPENDED, NOT HELD — by the ledger's own `SuspendOnSurprise`
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

  # THE SECOND WAVE — `--all` runs the persistence-parity pass ITSELF
  # over every target that came back clean from wave 1 AND binds
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

  # THE `dry_runs` COMPARISON SURFACE FINDS SOMETHING ON ITS OWN — item 5
  # of the detection plan. `--dry-run 1` turns every generated command
  # step into a `{"dry_run": …}` step, so the Ruby side of
  # `spec/fixtures/qa_sweep_all_dry_run_fixture` produces NO instances,
  # events or refusals — exactly what the fixture crate's own feature
  # answers — and the two sides differ on `dry_runs` alone.
  # `--self-consistency false` keeps the Rust rehydration door out of
  # it: this example is about ONE surface, proven in isolation.
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
