require "hecks"
require "hecks/ports/persistence/plugins/era"
require_relative "support/qa_sweep_all_fixture"

# `qa_sweep --all` / single-target: claim races and the `--modes` override.
# Own throwaway database: `hecks_qa_sweep_all_claims_spec`.
RSpec.describe "qa_sweep --all", :io do
  include_context "with a qa_sweep_all fixture", "hecks_qa_sweep_all_claims_spec"

  def spawn_racer(script, engineer)
    log = Tempfile.new(engineer)
    pid = Process.spawn("bundle", "exec", "ruby", script, InMemoryDomain::ROOT, @fixture_dir, "contested", engineer,
                        out: log, err: log, chdir: InMemoryDomain::ROOT)
    { pid: pid, log: log }
  end

  def collect_outcome(racer)
    _pid, status = Process.waitpid2(racer[:pid])
    racer[:log].rewind
    output = racer[:log].read.strip
    racer[:log].close
    { exitstatus: status.exitstatus, output: output }
  end

  # Starts two processes claiming the same target at once and answers what each ended with.
  def claim_race_outcomes
    script = File.join(@fixture_root, "claim_race.rb")
    File.write(script, CLAIM_RACE_SCRIPT)
    racers = %w[racer_a racer_b].map { |engineer| spawn_racer(script, engineer) }
    racers.map { |racer| collect_outcome(racer) }
  end

  it "lets exactly one of two real concurrent claims on the SAME target win", :aggregate_failures do
    identify_targets!("contested" => @target_domain_relpath)
    outcomes = claim_race_outcomes

    expect(outcomes.map { |o| o[:exitstatus] }.sort).to eq([0, 1])
    expect(outcomes.map { |o| o[:output] }).to contain_exactly("claimed", "refused")
  end

  # Sweeps `target`, expects a clean exit, and answers stdout.
  def sweep_ok(target, *args)
    stdout, _stderr, status = run_qa_sweep(target, *args)
    expect(status.exitstatus).to eq(0)
    stdout
  end

  # The fixture target's only capability is `sqlite`, so `--modes` yields just the ruby_only seat.
  context "with a target that has one capability" do
    before { identify_targets!("modes_one" => @target_domain_relpath) }

    it "prints the resolved modes and capabilities", :aggregate_failures do
      stdout = sweep_ok("modes_one", "--seeds", "2")

      expect(stdout).to include("resolved modes: ruby_only,self_consistency (capabilities=sqlite)")
      expect(stdout).to include("seed 1: held (ruby_only, self_consistency)")
    end

    # GUIDED_GENERATION is on in the real dials this fixture ledger loads,
    # so the sweep's one CoverageCampaign reports what its seeds reached.
    it "reports what the coverage campaign's seeds reached" do
      expect(sweep_ok("modes_one", "--seeds", "2")).to match(/^  coverage: \d+ distinct .* over 2 seed\(s\)/)
    end

    it "honours --modes as the enabled set" do
      stdout = sweep_ok("modes_one", "--seeds", "2", "--modes", "ruby_only")

      expect(stdout).to include("resolved modes: ruby_only (capabilities=sqlite)", "seed 1: held (ruby_only)")
    end
  end

  context "with a --modes set this target cannot resolve a comparison seat from" do
    before { identify_targets!("modes_none" => @target_domain_relpath) }

    it "refuses a mode set that resolves no comparison mode", :aggregate_failures do
      stdout, stderr, status = run_qa_sweep("modes_none", "--modes", "differential")

      expect(status.exitstatus).to eq(1)
      expect(stderr + stdout).to include("resolves no comparison mode at all")
    end

    it "refuses a mode that does not exist", :aggregate_failures do
      _stdout, stderr, status = run_qa_sweep("modes_none", "--modes", "telepathy")

      expect(status.exitstatus).to eq(1)
      expect(stderr).to include("no such mode: telepathy")
    end

    # Nothing was claimed or opened — the refusal came before the claim.
    it "refuses before claiming anything" do
      run_qa_sweep("modes_none", "--modes", "differential")
      Hecks.boot(@fixture_dir)

      expect(QualityControl::Target.find("modes_none").status).to eq("waiting")
    end
  end
end
