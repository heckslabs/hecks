require "hecks"
require "hecks/ports/persistence/plugins/era"
require_relative "support/qa_sweep_all_fixture"

# `qa_sweep --all` ledger lifecycle: role provisioning, empty rotation, stale-hold reclaim,
# and every child failing. See `spec/support/qa_sweep_all_fixture.rb` for the shared setup.
RSpec.describe "qa_sweep --all", :io do
  include_context "with a qa_sweep_all fixture", "hecks_qa_sweep_all_lifecycle_spec"

  BROKEN_TARGETS = { "broken_a" => "qa/stress_domains/__qa_sweep_all_spec_nope_a__",
                     "broken_b" => "qa/stress_domains/__qa_sweep_all_spec_nope_b__" }.freeze

  # hecks_qa's role row and the database's owner, as the ledger's own connection reads them.
  def role_and_owner
    db = PG.connect(dbname: @qa_sweep_all_database)
    role = db.exec("SELECT rolsuper, rolbypassrls FROM pg_roles WHERE rolname = 'hecks_qa'")[0]
    owner = db.exec("SELECT pg_get_userbyid(datdba) AS owner FROM pg_database WHERE datname = current_database()")[0]
    db.close
    [role, owner]
  end

  # Two targets, one with a claim older than its 900s window and one with a live claim, swept.
  def sweep_with_two_holds
    identify_targets!("stale_one" => @target_domain_relpath, "fresh_one" => @target_domain_relpath)
    now = Time.now.to_i
    QualityControl::Target.find("stale_one").claim!(held_by: { value: "ghost" }, now: { value: now - 5_000 })
    QualityControl::Target.find("fresh_one").claim!(held_by: { value: "busy" }, now: { value: now })
    run_qa_sweep("--all", "--seeds", "1")
  end

  # Runs the operator step `qa_postgres_role <database>` against a disposable database; checks
  # its report, idempotence on a second run, and that the resulting owner is an ordinary role.
  it "qa_postgres_role hands the ledger's database to hecks_qa" do
    expect(@role_report).to include("#{@qa_sweep_all_database} is hecks_qa's", "database #{@qa_sweep_all_database}: owner")
  end

  it "qa_postgres_role is idempotent", :aggregate_failures do
    again = QaLedgerRole.provision!(@qa_sweep_all_database)

    expect(again).to include("already: role hecks_qa exists, ordinary",
                             "already: database #{@qa_sweep_all_database} already owned by hecks_qa")
    expect(again).not_to include("did:")
  end

  it "qa_postgres_role leaves hecks_qa an ordinary owner, and a boot over that URL is the fenced kind", :aggregate_failures do
    role, owner = role_and_owner

    expect([role, owner["owner"]]).to eq([{ "rolsuper" => "f", "rolbypassrls" => "f" }, "hecks_qa"])
    # ...and a boot over that URL is the ordinary, fenced kind: no refusal, no warning.
    expect { identify_targets!("fenced" => @target_domain_relpath) }.not_to output.to_stderr
  end

  it "is a clean, explicit no-op when the rotation is completely empty", :aggregate_failures do
    stdout, _stderr, status = run_qa_sweep("--all")

    expect(status.exitstatus).to eq(0)
    expect(stdout).to include("rotation is empty")
  end

  # A claim older than its 900s window is reclaimed; `fresh_one`'s live claim must stay untouched.
  it "sweeps a target whose hold has gone stale, and names the reclaim", :aggregate_failures do
    stdout, _stderr, status = sweep_with_two_holds

    expect(status.exitstatus).to eq(0), stdout
    expect(stdout).to match(/^reclaimed stale hold: stale_one \(held by ghost, \d+s ago\)$/)
    expect(stdout).to include("clean (1): stale_one")
  end

  it "leaves a live hold alone", :aggregate_failures do
    stdout, = sweep_with_two_holds
    Hecks.boot(@fixture_dir)

    expect(stdout).not_to include("fresh_one")
    expect(%w[stale_one fresh_one].map { |name| QualityControl::Target.find(name).status }).to eq(%w[waiting held])
    expect(QualityControl::Target.find("fresh_one").held_by.to_h).to eq(value: "busy")
  end

  it "exits 1 when every child hit an operational error and nothing was ever found", :aggregate_failures do
    identify_targets!(BROKEN_TARGETS)

    stdout, _stderr, status = run_qa_sweep("--all")

    expect(status.exitstatus).to eq(1)
    expect(stdout).to include("clean (0): none", "OPERATIONAL ERRORS (2)")
    expect(stdout).not_to include("FOUND SOMETHING")
  end
end
