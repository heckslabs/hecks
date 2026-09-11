require "hecks"
require "hecks/ports/persistence/plugins/era"
require_relative "support/postgres_probe"
require "open3"
require "fileutils"
require "pathname"

# `bin/qa_sweep --persistence-parity`, PROVEN AGAINST THE REAL THING —
# same discipline `spec/qa_sweep_all_spec.rb` (read that file's own header
# FIRST) already established for `--all`: a REAL `bin/qa_sweep` subprocess,
# against a REAL, disposable Postgres-backed fixture ledger that loads the
# REAL `qa/bluebook/quality_control.bluebook` (symlinked, never copied),
# never the real `hecks_quality_control` ledger itself. This file reuses
# that exact pattern rather than inventing a new one — see this repo's own
# instructions for this work.
#
# `examples/directory` IS THE REAL TARGET HERE, ON PURPOSE — not a fixture
# stand-in. This mode exists specifically because `directory`'s own
# `compute`/`rekey` translation edge is the one domain in this corpus that
# actually exercises PostgresEra-bound SQL compilation (see `lib/hecks/
# fuzzing/persistence_parity.rb`'s own header), so proving this mode works
# means proving it against THAT domain, loaded straight off disk exactly
# as committed — never copied or rewritten by this spec (`IsolatedBoot`
# does its own copy-and-rebind per ephemeral boot; this spec only ever
# points a real `bin/qa_sweep` subprocess at the real `examples/directory`
# path, the same way a real sweep would).
RSpec.describe "bin/qa_sweep --persistence-parity", :io do
  QA_SWEEP_PERSISTENCE_PARITY_DATABASE = "hecks_qa_sweep_persistence_parity_spec".freeze

  # LINE-FOR-LINE `spec/qa_sweep_all_spec.rb`'s OWN `FIXTURE_HECKSAGON` —
  # see that file's own comment on why the `CI`/`IssueTracker` ports stay
  # unbound here (this spec never dispatches `Clearance.CI.Run` either).
  #
  # NAMED `LEDGER_HECKSAGON`, NOT THE SAME `FIXTURE_HECKSAGON` THAT FILE
  # USES — found live, wiring this spec up: `CONST = value` written
  # directly inside an `RSpec.describe do ... end` block is a real Ruby
  # gotcha — it assigns at the block's own LEXICAL scope (top-level, i.e.
  # `Object`), not inside the dynamically-created example-group class,
  # because `describe` takes an ordinary BLOCK, not a `class`/`module`
  # keyword body. Every spec file that writes `FIXTURE_HECKSAGON = ...`
  # this way is therefore defining the SAME top-level constant — harmless
  # between this file and `qa_sweep_all_spec.rb` only because their
  # content happens to be identical, but genuinely corrupting between
  # either of them and `spec/fuzzing/persistence_parity_spec.rb`'s own
  # DIFFERENT-content `FIXTURE_HECKSAGON`: whichever spec file Ruby loads
  # LAST silently overwrites the constant the FIRST one's own `before(:all)`
  # reads at RUN time, so a fixture domain ends up written from another
  # spec's own hecksagon text entirely. Confirmed live by the exact
  # `Hecks::Bluebook::DSL::Malformed` this collision produced before this
  # rename existed. Never reused a plain `FIXTURE_*` name again here.
  LEDGER_HECKSAGON = <<~RUBY.freeze
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

      QualityControl::Ticket.port "IssueTracker" do
        asks "File", to: Ticket do
          answers "IssueFiled"
          refuses "IssueFilingRefused"
        end

        tells "Closed", to: Ticket do
          emits "IssueClosedUpstream"
        end
      end

      QualityControl::Clearance.port "CI" do
        asks "Run", to: Clearance do
          answers "SuitePassed"
          refuses "SuiteFailed"
        end
      end
    end
  RUBY

  # A NON-POSTGRESERA-BOUND TARGET, FOR THE ELIGIBILITY GATE'S OWN
  # negative example — `Heki`-bound, the plainest "not PostgresEra at
  # all" binding this corpus has, needing no real server of its own.
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
    FileUtils.ln_s(File.join(InMemoryDomain::ROOT, "qa/bluebook/quality_control.bluebook"),
                   File.join(@fixture_dir, "quality_control.bluebook"))
    File.write(File.join(@fixture_dir, "quality_control.hecksagon"), LEDGER_HECKSAGON)
    File.write(File.join(@fixture_dir, "quality_control.world"), <<~RUBY)
      Hecks.world "QualityControl" do
        realm "QA"
        persisted_by("PostgresEra") { database "#{QA_SWEEP_PERSISTENCE_PARITY_DATABASE}" }
      end
    RUBY

    # LIVING INSIDE THE REAL REPO ROOT, exactly `qa_sweep_all_spec.rb`'s
    # own reasoning — `bin/qa_sweep` resolves a `Target`'s own `path` as
    # `File.join(ROOT, target_path)` against the real repository root.
    @ineligible_dir = Dir.mktmpdir("qa_sweep_persistence_parity_spec_target-", InMemoryDomain::ROOT)
    File.write(File.join(@ineligible_dir, "ineligible.bluebook"), INELIGIBLE_TARGET_BLUEBOOK)
    File.write(File.join(@ineligible_dir, "ineligible.hecksagon"), INELIGIBLE_TARGET_HECKSAGON)
    @ineligible_relpath = Pathname.new(@ineligible_dir).relative_path_from(Pathname.new(InMemoryDomain::ROOT)).to_s

    admin = PG.connect(dbname: "postgres")
    admin.exec("DROP DATABASE IF EXISTS #{QA_SWEEP_PERSISTENCE_PARITY_DATABASE} WITH (FORCE)")
    admin.exec("CREATE DATABASE #{QA_SWEEP_PERSISTENCE_PARITY_DATABASE}")
    admin.close
  end

  after(:all) do
    next unless PostgresProbe.available?

    admin = PG.connect(dbname: "postgres")
    admin.exec("DROP DATABASE IF EXISTS #{QA_SWEEP_PERSISTENCE_PARITY_DATABASE} WITH (FORCE)")
    admin.close
    FileUtils.remove_entry(@fixture_root)
    FileUtils.remove_entry(@ineligible_dir)

    # THIS SPEC'S OWN DISPOSABLE PERSISTENCE-PARITY DATABASE — a real
    # `bin/qa_sweep --persistence-parity` subprocess creates it itself
    # (see that script's own comment: a fixed, dedicated, never-the-real-
    # ledger name, never dropped by the script itself because dropping a
    # shared database out from under a concurrent run would be
    # destructive). This spec is the one place that's actually safe to
    # drop it — nothing else in CI runs this spec concurrently with
    # itself — so it cleans up after both examples here.
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
  end

  def run_qa_sweep(*args)
    Open3.capture3(
      { "QA_SWEEP_DOMAIN_DIR" => @fixture_dir },
      "bundle", "exec", "ruby", File.join(InMemoryDomain::ROOT, "bin/qa_sweep"), *args,
      chdir: InMemoryDomain::ROOT
    )
  end

  def identify_target!(reference, path)
    Hecks.boot(@fixture_dir)
    QualityControl::Target.identify!(reference: { value: reference }, path: { value: path })
  end

  # `abort` (Kernel#abort) WRITES TO STDERR, not stdout — every assertion
  # in this file that checks an `abort` message reads `stderr`, never
  # `stdout`, unlike the `--all` mode's own OWN spec (`qa_sweep_all_spec
  # .rb`), which reads a MERGED stdout+stderr stream because `--all`'s own
  # children are spawned with `out: log, err: log` (`spawn_sweep_child`'s
  # own comment) — a single, non-`--all` invocation of this script keeps
  # the two streams separate, exactly as `Open3.capture3` hands them back.
  it "refuses --all combined with --persistence-parity before ever booting the ledger" do
    _stdout, stderr, status = run_qa_sweep("--all", "--persistence-parity")

    expect(status.exitstatus).to eq(1)
    expect(stderr).to include("does not combine with --all")
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

    # NEVER CLAIMED — an ineligible target must be left exactly as found,
    # not held by a sweep that was always going to abort.
    Hecks.boot(@fixture_dir)
    row = QualityControl::Target.find("ineligible")
    expect(row.status).to eq("waiting")
  end

  # THE REAL PAYOFF — `examples/directory`, shelved out of THIS repository's
  # own live rotation for exactly the structural reason this mode exists to
  # close (see `lib/hecks/fuzzing/persistence_parity.rb`'s own header),
  # restored here into a THROWAWAY fixture ledger's own rotation — proving
  # both the generic `Target.Shelve`/`Target.Restore` mechanics this repo's
  # own instructions asked to be checked, AND a real, full
  # claim -> sweep -> conclude -> release cycle against real PostgresEra
  # SQL, without ever touching the real `hecks_quality_control` ledger.
  it "restores a shelved PostgresEra-bound target and sweeps it clean, end to end, against real PostgresEra" do
    identify_target!("directory", "examples/directory")

    Hecks.boot(@fixture_dir)
    target = QualityControl::Target.find("directory")
    target = target.shelve!(reason: { value: "structurally can't be reached by any Memory-only fuzz/replay path" })
    expect(target.status).to eq("shelved")

    target = target.restore!
    expect(target.status).to eq("waiting")

    stdout, stderr, status = run_qa_sweep("directory", "--persistence-parity", "--seeds", "2")

    expect(status.exitstatus).to eq(0), "expected a clean sweep, got:\nSTDOUT:\n#{stdout}\nSTDERR:\n#{stderr}"
    expect(stdout).to include("Memory vs real PostgresEra (directory) — persistence-adapter parity")
    expect(stdout).to include("seed 1: held", "seed 2: held")
    expect(stdout).to include("clean — directory concluded and released.")
    expect(stdout).to include("mode=persistence_parity")

    # `held_by` — `Target.Release`'s own bluebook declaration only ever
    # `sets :last_swept, to: :now` (qa/bluebook/quality_control.bluebook,
    # "THE ARGUMENT IS `now`..."); nothing resets `held_by` back to its
    # "nobody" default on release — `status`, already checked above, is
    # what actually tracks "currently held or not." The last claimer's
    # own name simply stays on record as an audit trail.
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
