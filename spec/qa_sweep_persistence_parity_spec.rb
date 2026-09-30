require "hecks"
require "hecks/ports/persistence/plugins/era"
require_relative "support/postgres_probe"
require_relative "support/qa_ledger_role"
require "open3"
require "hecks/quality_control/cli/child"
require "fileutils"
require "pathname"

# `qa_sweep --persistence-parity` against a real subprocess and the real `examples/directory`,
# whose `compute`/`rekey` edge exercises PostgresEra SQL compilation.
RSpec.describe "qa_sweep --persistence-parity", :io do
  QA_SWEEP_PERSISTENCE_PARITY_DATABASE = "hecks_qa_sweep_persistence_parity_spec".freeze

  # Same as `FIXTURE_HECKSAGON` in `spec/support/qa_sweep_all_fixture.rb`, under another name:
  # a constant assigned inside `RSpec.describe do ... end` lands on `Object`, so a shared name
  # would be overwritten by whichever spec file loads last.
  LEDGER_HECKSAGON = <<~RUBY.freeze
    Hecks::Chapters.load!("QualityControl")

    Hecks.hecksagon "QualityControl" do
      uses_framework "Governance"

      QualityControl::Target.persisted_by("PostgresEra")
      QualityControl::Sweep.persisted_by("PostgresEra")
      QualityControl::Bug.persisted_by("PostgresEra")
      QualityControl::Angle.persisted_by("PostgresEra")
      QualityControl::Ticket.persisted_by("PostgresEra")
      QualityControl::Patch.persisted_by("PostgresEra")
      QualityControl::Improvement.persisted_by("PostgresEra")
      QualityControl::Clearance.persisted_by("PostgresEra")
    end
  RUBY

  # A Heki-bound target for the eligibility gate's negative example.
  INELIGIBLE_TARGET_BLUEBOOK = <<~RUBY.freeze
    Hecks.bluebook "QaSweepPersistenceParityIneligibleFixture" do
      vision "A trivially well-behaved, non-PostgresEra-bound target — proves --persistence-parity's own eligibility gate refuses it before ever claiming or opening a sweep."

      aggregate "Widget" do
        identified_by :reference
        attribute :reference, WidgetReference

        value_object("WidgetReference") { attribute :value, String }

        command "Open" do
          attribute :reference, WidgetReference
          sets :reference
          emits "WidgetOpened"
        end
      end
    end
  RUBY

  INELIGIBLE_TARGET_HECKSAGON = <<~RUBY.freeze
    Hecks.hecksagon "QaSweepPersistenceParityIneligibleFixture" do
      QaSweepPersistenceParityIneligibleFixture::Widget.persisted_by("Heki")
    end
  RUBY

  before(:all) do
    skip "no reachable Postgres — start one to run this spec" unless PostgresProbe.available?

    @fixture_root = Dir.mktmpdir("qa_sweep_persistence_parity_spec")
    @fixture_dir  = File.join(@fixture_root, "bluebook")
    FileUtils.mkdir_p(@fixture_dir)
    File.write(File.join(@fixture_dir, "quality_control.hecksagon"), LEDGER_HECKSAGON)
    File.write(File.join(@fixture_dir, "context_map.hecksagon"), InMemoryDomain::GOVERNANCE_POSTGRES_ERA_HECKSAGON)
    url = QaLedgerRole.url(QA_SWEEP_PERSISTENCE_PARITY_DATABASE)
    File.write(File.join(@fixture_dir, "quality_control.world"), <<~RUBY)
      Hecks.world "QualityControl" do
        realm "QA"
        persisted_by("PostgresEra") { database "#{url}" }
      end
    RUBY
    File.write(File.join(@fixture_dir, "governance.world"), InMemoryDomain.governance_postgres_era_world(url))

    # Inside the real repo `ROOT`, because `qa_sweep` resolves a target path against it.
    @ineligible_dir = Dir.mktmpdir("qa_sweep_persistence_parity_spec_target-", InMemoryDomain::ROOT)
    File.write(File.join(@ineligible_dir, "ineligible.bluebook"), INELIGIBLE_TARGET_BLUEBOOK)
    File.write(File.join(@ineligible_dir, "ineligible.hecksagon"), INELIGIBLE_TARGET_HECKSAGON)
    @ineligible_relpath = Pathname.new(@ineligible_dir).relative_path_from(Pathname.new(InMemoryDomain::ROOT)).to_s

    admin = PG.connect(dbname: "postgres")
    admin.exec("DROP DATABASE IF EXISTS #{QA_SWEEP_PERSISTENCE_PARITY_DATABASE} WITH (FORCE)")
    admin.exec("CREATE DATABASE #{QA_SWEEP_PERSISTENCE_PARITY_DATABASE}")
    admin.close
    # The ledger's operator step, run against this spec's own database.
    QaLedgerRole.provision!(QA_SWEEP_PERSISTENCE_PARITY_DATABASE)
  end

  after(:all) do
    next unless PostgresProbe.available?

    admin = PG.connect(dbname: "postgres")
    admin.exec("DROP DATABASE IF EXISTS #{QA_SWEEP_PERSISTENCE_PARITY_DATABASE} WITH (FORCE)")
    admin.close
    FileUtils.remove_entry(@fixture_root)
    FileUtils.remove_entry(@ineligible_dir)

    # The subprocess creates this database itself and never drops it, since dropping a shared
    # database under a concurrent run would be destructive; this spec runs alone, so it cleans up.
    admin = PG.connect(dbname: "postgres")
    admin.exec('DROP DATABASE IF EXISTS "hecks_qa_persistence_parity" WITH (FORCE)')
    admin.close
  end

  before { reset_schema! }

  def reset_schema!
    scrub = PG.connect(dbname: QA_SWEEP_PERSISTENCE_PARITY_DATABASE)
    scrub.exec("DROP SCHEMA public CASCADE")
    scrub.exec("CREATE SCHEMA public")
    scrub.close
    QaLedgerRole.own_public!(QA_SWEEP_PERSISTENCE_PARITY_DATABASE)
  end

  def run_qa_sweep(*args)
    Open3.capture3(
      { "QA_SWEEP_DOMAIN_DIR" => @fixture_dir },
      *Hecks::QualityControlCli::Child.argv(InMemoryDomain::ROOT, "qa_sweep", *args),
      chdir: InMemoryDomain::ROOT
    )
  end

  def identify_target!(reference, path)
    Hecks.boot(@fixture_dir)
    QualityControl::Target.identify!(reference: { value: reference }, path: { value: path })
  end

  # `abort` writes to stderr, so abort assertions read `stderr`; a single non-`--all` run keeps the
  # streams separate, unlike `--all` children, which log to one merged stream.
  # `--all --persistence-parity` folds back to plain `--all` with the parity wave forced on, rather
  # than narrowing every child to one mode (which would abort the ineligible target). Wave 2 then
  # runs over `directory` alone, the only `postgres_era`-capable target.
  it "runs --all normally and forces the parity wave on when combined with --persistence-parity" do
    identify_target!("directory", "examples/directory")
    identify_target!("ineligible", @ineligible_relpath)

    stdout, stderr, status = run_qa_sweep("--all", "--persistence-parity", "--seeds", "2")

    expect(status.exitstatus).to eq(0), "expected a clean --all, got:\nSTDOUT:\n#{stdout}\nSTDERR:\n#{stderr}"
    expect(stdout).to include("clean (3): directory, ineligible, directory [parity wave]")
    expect(stdout).to include("parity wave: Memory vs real PostgresEra for 1 target(s), at most " \
                              "#{QualityControlDials::SWEEP_MAX_PARALLEL} at once: directory")
    expect(stdout).to include(
      "  directory: ruby_only,self_consistency (capabilities: postgres_era,sqlite,translations; " \
      "deferred: persistence_parity)"
    )
    expect(stdout).to include(
      "  directory [parity wave]: persistence_parity (capabilities: postgres_era,sqlite,translations)"
    )
    expect(stdout).to match(/^  ineligible: ruby_only,self_consistency \(capabilities: sqlite\)$/)
    expect(stdout).not_to include("declares no persisted_by")
  end

  it "still skips the parity wave under --all when --no-parity is also given, even with --persistence-parity" do
    identify_target!("directory", "examples/directory")

    stdout, _stderr, status = run_qa_sweep("--all", "--persistence-parity", "--no-parity", "--seeds", "2")

    expect(status.exitstatus).to eq(0)
    expect(stdout).not_to include("parity wave")
  end

  it "refuses --persistence-parity with no explicit target-reference" do
    _stdout, stderr, status = run_qa_sweep("--persistence-parity")

    expect(status.exitstatus).to eq(1)
    expect(stderr).to include("needs an explicit target-reference")
  end

  it "refuses a target with no persisted_by(\"PostgresEra\") binding at all — an operational error, not a finding" do
    identify_target!("ineligible", @ineligible_relpath)

    _stdout, stderr, status = run_qa_sweep("ineligible", "--persistence-parity")

    expect(status.exitstatus).to eq(1)
    expect(stderr).to include("declares no persisted_by(\"PostgresEra\") binding")

    # An ineligible target must be left as found, not held by a sweep that was going to abort.
    Hecks.boot(@fixture_dir)
    row = QualityControl::Target.find("ineligible")
    expect(row.status).to eq("waiting")
  end

  # `examples/directory` is shelved out of the live rotation because Memory-only paths cannot
  # reach it; restore it into a fixture ledger and run a full claim, sweep, conclude, release.
  it "restores a shelved PostgresEra-bound target and sweeps it clean, end to end, against real PostgresEra" do
    identify_target!("directory", "examples/directory")

    Hecks.boot(@fixture_dir)
    target = QualityControl::Target.find("directory")
    target = target.shelve!(reason: { value: "structurally can't be reached by any Memory-only fuzz/replay path" })
    expect(target.status).to eq("shelved")

    target = target.restore!(reason: { value: "PR #564 fixed the era-check blocker; PostgresEra-bound domains fuzz again" })
    expect(target.status).to eq("waiting")

    stdout, stderr, status = run_qa_sweep("directory", "--persistence-parity", "--seeds", "2")

    expect(status.exitstatus).to eq(0), "expected a clean sweep, got:\nSTDOUT:\n#{stdout}\nSTDERR:\n#{stderr}"
    expect(stdout).to include("Memory vs real PostgresEra (directory) — persistence-adapter parity")
    expect(stdout).to include("seed 1: held", "seed 2: held")
    expect(stdout).to include("clean — directory concluded and released.")
    expect(stdout).to include("mode=persistence_parity")

    # `Target.Release` only sets `last_swept`; `held_by` is never reset, as an audit trail.
    row = QualityControl::Target.find("directory")
    expect(row.status).to eq("waiting")
    expect(row.held_by.to_h).to eq(value: "qa_sweep")
  end

  it "clamps --seeds down to QualityControlDials::PERSISTENCE_PARITY_SEED_CAP and says so" do
    identify_target!("directory-clamp", "examples/directory")

    stdout, _stderr, status = run_qa_sweep("directory-clamp", "--persistence-parity", "--seeds", "999")

    expect(status.exitstatus).to eq(0)
    expect(stdout).to include("exceeds QualityControlDials::PERSISTENCE_PARITY_SEED_CAP", "clamping down")
  end
end
