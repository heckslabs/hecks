require "hecks"
require "hecks/ports/persistence/plugins/era"
require_relative "support/qa_sweep_all_fixture"

# `bin/qa_sweep --all`, PROVEN AGAINST THE REAL THING — split out of what
# used to be one 710-line `qa_sweep_all_spec.rb` (Phase 2 of the CI speed
# effort; see `spec/support/qa_sweep_all_fixture.rb`'s own header for the
# full "why a disposable ledger, why QA_SWEEP_DOMAIN_DIR" reasoning this
# fixture rests on). THIS FILE covers the ledger-lifecycle surface: the
# operator role-provisioning step, an empty rotation, a stale-hold
# reclaim, and every child failing outright. The other three groups
# (concurrency mechanics, claim races + modes, report formatting +
# persistence parity) live in their own sibling files, each with its own
# throwaway database name so `parallel_rspec` can run all four
# concurrently without any two racing the same scratch resource.
RSpec.describe "bin/qa_sweep --all", :io do
  include_context "with a qa_sweep_all fixture", "hecks_qa_sweep_all_lifecycle_spec"

  # THE OPERATOR STEP, PROVEN ON A DISPOSABLE DATABASE (BUG#24) — the
  # exact `bin/qa_postgres_role <database>` the real ledger's `.world`
  # header asks an operator to run once against `hecks_quality_control`,
  # already run for real in `before(:all)` against this spec's own
  # throwaway database. What it reports, what a second run reports
  # (idempotent: nothing left to do), and that the resulting owner is
  # genuinely an ORDINARY role — the whole point — are the three facts an
  # operator is being asked to trust.
  it "bin/qa_postgres_role hands the ledger's database to hecks_qa, an ordinary owner, idempotently" do
    expect(@role_report).to include("#{@qa_sweep_all_database} is hecks_qa's")
    expect(@role_report).to include("database #{@qa_sweep_all_database}: owner")

    again = QaLedgerRole.provision!(@qa_sweep_all_database)
    expect(again).to include("already: role hecks_qa exists, ordinary")
    expect(again).to include("already: database #{@qa_sweep_all_database} already owned by hecks_qa")
    expect(again).not_to include("did:")

    db = PG.connect(dbname: @qa_sweep_all_database)
    role = db.exec("SELECT rolsuper, rolbypassrls FROM pg_roles WHERE rolname = 'hecks_qa'")[0]
    owner = db.exec("SELECT pg_get_userbyid(datdba) AS owner FROM pg_database WHERE datname = current_database()")[0]
    db.close
    expect(role).to eq("rolsuper" => "f", "rolbypassrls" => "f")
    expect(owner["owner"]).to eq("hecks_qa")

    # ...and a boot over that URL is the ordinary, fenced kind: it neither
    # refuses nor warns, where the ambient superuser would have refused
    expect { identify_targets!("fenced" => @target_domain_relpath) }.not_to output.to_stderr
  end

  it "is a clean, explicit no-op when the rotation is completely empty" do
    stdout, _stderr, status = run_qa_sweep("--all")

    expect(status.exitstatus).to eq(0)
    expect(stdout).to include("rotation is empty")
  end

  # THE STALE-HOLD RECLAIM — the ledger's own "a claim that goes stale is
  # taken by whoever is next", finally offered to `--all`. `stale_one`'s
  # claim is older than its own 900s window; `fresh_one`'s is live, and
  # must be left exactly as it is.
  it "sweeps a target whose hold has gone stale, names the reclaim, and leaves a live hold alone" do
    identify_targets!("stale_one" => @target_domain_relpath, "fresh_one" => @target_domain_relpath)
    now = Time.now.to_i
    QualityControl::Target.find("stale_one").claim!(held_by: { value: "ghost" }, now: { value: now - 5_000 })
    QualityControl::Target.find("fresh_one").claim!(held_by: { value: "busy" }, now: { value: now })

    stdout, _stderr, status = run_qa_sweep("--all", "--seeds", "1")

    expect(status.exitstatus).to eq(0), stdout
    expect(stdout).to match(/^reclaimed stale hold: stale_one \(held by ghost, \d+s ago\)$/)
    expect(stdout).to include("clean (1): stale_one")
    expect(stdout).not_to include("fresh_one")

    Hecks.boot(@fixture_dir)
    expect(QualityControl::Target.find("stale_one").status).to eq("waiting")
    fresh = QualityControl::Target.find("fresh_one")
    expect(fresh.status).to eq("held")
    expect(fresh.held_by.to_h).to eq(value: "busy")
  end

  it "exits 1 when every child hit an operational error and nothing was ever found" do
    identify_targets!(
      "broken_a" => "qa/stress_domains/__qa_sweep_all_spec_nope_a__",
      "broken_b" => "qa/stress_domains/__qa_sweep_all_spec_nope_b__"
    )

    stdout, _stderr, status = run_qa_sweep("--all")

    expect(status.exitstatus).to eq(1)
    expect(stdout).to include("clean (0): none")
    expect(stdout).to include("OPERATIONAL ERRORS (2)")
    expect(stdout).not_to include("FOUND SOMETHING")
  end
end
