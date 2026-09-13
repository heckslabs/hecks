require "hecks"
require "hecks/ports/persistence/plugins/era"
require_relative "support/qa_sweep_all_fixture"

# `bin/qa_sweep --all` / single-target — CLAIM RACES AND MODES. One of
# four sibling files split out of the original `qa_sweep_all_spec.rb`
# (Phase 2 of the CI speed effort — see `spec/qa_sweep_all_lifecycle_
# spec.rb`'s own header and `spec/support/qa_sweep_all_fixture.rb` for
# the full context). This file proves the claim race a real concurrent
# `Target.Claim` resolves, and the `--modes` override on a single-target
# sweep. Own throwaway database: `hecks_qa_sweep_all_claims_spec`.
RSpec.describe "bin/qa_sweep --all", :io do
  include_context "with a qa_sweep_all fixture", "hecks_qa_sweep_all_claims_spec"

  it "lets exactly one of two real concurrent claims on the SAME target win" do
    identify_targets!("contested" => @target_domain_relpath)
    script = File.join(@fixture_root, "claim_race.rb")
    File.write(script, CLAIM_RACE_SCRIPT)

    racers = %w[racer_a racer_b].map do |engineer|
      log = Tempfile.new(engineer)
      pid = Process.spawn("bundle", "exec", "ruby", script, InMemoryDomain::ROOT, @fixture_dir, "contested", engineer,
                          out: log, err: log, chdir: InMemoryDomain::ROOT)
      { pid: pid, log: log }
    end

    outcomes = racers.map do |racer|
      _pid, status = Process.waitpid2(racer[:pid])
      racer[:log].rewind
      output = racer[:log].read.strip
      racer[:log].close
      { exitstatus: status.exitstatus, output: output }
    end

    expect(outcomes.map { |o| o[:exitstatus] }.sort).to eq([0, 1])
    expect(outcomes.map { |o| o[:output] }).to contain_exactly("claimed", "refused")
  end

  # MODES ARE DATA — `bin/qa_sweep` prints the one rule's answer
  # (`enabled ∩ eligible`, `Hecks::Fuzzing::TargetCapabilities`) on its
  # own `resolved modes:` line, and `--modes` overrides the enabled set
  # for one run. The fixture target binds Heki and has no Cargo feature,
  # so its capabilities are exactly `sqlite` — the ruby_only seat, with
  # self-consistency folded in, and nothing else.
  it "prints the resolved modes and capabilities, and honours --modes as the enabled set" do
    identify_targets!("modes_one" => @target_domain_relpath)

    stdout, _stderr, status = run_qa_sweep("modes_one", "--seeds", "2")
    expect(status.exitstatus).to eq(0)
    expect(stdout).to include("resolved modes: ruby_only,self_consistency (capabilities=sqlite)")
    expect(stdout).to include("seed 1: held (ruby_only, self_consistency)")
    # GUIDED_GENERATION is on in the real dials this fixture ledger loads,
    # so the sweep's one CoverageCampaign reports what its seeds reached.
    expect(stdout).to match(/^  coverage: \d+ distinct .* over 2 seed\(s\)/)

    stdout, _stderr, status = run_qa_sweep("modes_one", "--seeds", "2", "--modes", "ruby_only")
    expect(status.exitstatus).to eq(0)
    expect(stdout).to include("resolved modes: ruby_only (capabilities=sqlite)")
    expect(stdout).to include("seed 1: held (ruby_only)")
  end

  it "refuses, before claiming anything, a --modes set this target cannot resolve a comparison seat from" do
    identify_targets!("modes_none" => @target_domain_relpath)

    stdout, stderr, status = run_qa_sweep("modes_none", "--modes", "differential")
    expect(status.exitstatus).to eq(1)
    expect(stderr + stdout).to include("resolves no comparison mode at all")

    _stdout, stderr, status = run_qa_sweep("modes_none", "--modes", "telepathy")
    expect(status.exitstatus).to eq(1)
    expect(stderr).to include("no such mode: telepathy")

    # Nothing was claimed or opened — the refusal came before the claim.
    Hecks.boot(@fixture_dir)
    expect(QualityControl::Target.find("modes_none").status).to eq("waiting")
  end
end
