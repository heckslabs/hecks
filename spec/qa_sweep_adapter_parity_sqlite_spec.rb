require "hecks"
require "hecks/ports/persistence/plugins/era"
require_relative "support/postgres_probe"
require_relative "support/qa_ledger_role"
require "open3"
require "fileutils"
require "pathname"

# `bin/qa_sweep`'s `adapter_parity_sqlite` mode, PROVEN AGAINST THE REAL
# THING — same discipline `spec/qa_sweep_persistence_parity_spec.rb`
# (read that file's own header first) already established: a REAL
# `bin/qa_sweep` subprocess against a REAL, disposable Postgres-backed
# fixture LEDGER, never the real `hecks_quality_control` ledger itself.
#
# THE SWEPT TARGET, UNLIKE THAT FILE'S OWN, NEEDS NO PostgresEra BINDING
# AT ALL — that is the entire point of this mode. `sqlite` is a
# capability EVERY domain has (`Hecks::Fuzzing::TargetCapabilities.infer`
# always includes it, proven in `spec/fuzzing/target_capabilities_spec.rb`),
# and this mode's own pair (`Hecks::Fuzzing::PersistenceParity.diff(left:
# :memory, right: :sqlite)`, `QualityControlDials::ADAPTER_PARITY_PAIRS`)
# needs no disposable database or schema lifecycle the way `persistence_
# parity`'s Memory-vs-PostgresEra pair does — see that module's own
# header. So unlike `persistence_parity`, this mode is not a DEFERRED
# mode (`TargetCapabilities::DEFERRED_MODES` does not name it) and is
# not a wave of its own: it folds straight into the ordinary per-seed
# loop, on ANY target, the moment `QualityControlDials::MODES[
# :adapter_parity_sqlite]` (or `--modes`) turns it on — proven here on
# the plainest possible target, a Memory-bound one with no PostgresEra
# binding in sight.
RSpec.describe "bin/qa_sweep adapter_parity_sqlite", :io do
  QA_SWEEP_ADAPTER_PARITY_SQLITE_DATABASE = "hecks_qa_sweep_adapter_parity_sqlite_spec".freeze

  # LINE-FOR-LINE `spec/qa_sweep_all_spec.rb`'s OWN `FIXTURE_HECKSAGON`,
  # RENAMED — see that file's own comment (and `spec/fuzzing/
  # persistence_parity_spec.rb`'s own, longer one) on why every spec file
  # that boots a throwaway `QualityControl` ledger must give its own
  # top-level fixture constants a name no OTHER spec file also uses:
  # `CONST = value` inside an `RSpec.describe do ... end` block assigns
  # at the block's own lexical (top-level) scope, so two files reusing
  # the same bare name silently overwrite each other's fixture text.
  LEDGER_HECKSAGON_FOR_ADAPTER_PARITY_SQLITE_SPEC = <<~RUBY.freeze
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

  # THE SAME TRIVIAL WIDGET `spec/qa_sweep_all_spec.rb`'s OWN
  # `FIXTURE_TARGET_BLUEBOOK` uses, renamed — bound to `Memory` (not
  # `PostgresEra`, not even `Heki`) to make the point as plainly as
  # possible: this mode reaches a target that declares nothing about
  # PostgresEra at all.
  ADAPTER_PARITY_SQLITE_TARGET_BLUEBOOK = <<~RUBY.freeze
    Hecks.bluebook "QaSweepAdapterParitySqliteFixtureTarget" do
      vision "A trivially well-behaved sweep target, authored only to prove bin/qa_sweep's adapter_parity_sqlite mode reaches an ordinary, non-PostgresEra-bound domain, never this repository's own live, actively-changing QA corpus."

      aggregate "Widget" do
        description "One numbered widget and a bump count — nothing a fuzzer can ever catch."

        identified_by :reference

        attribute :reference, WidgetReference
        attribute :count,     WidgetCount

        value_object "WidgetReference" do
          attribute :value, String, pattern: '[^ \\t\\n\\r]'
          invariant("a widget is referenced") { !value.to_s.empty? }
        end

        value_object "WidgetCount" do
          attribute :value, Integer, default: 0
          invariant("a count never goes negative") { !value.negative? }
        end

        command "Open" do
          attribute :reference, WidgetReference

          sets :reference

          emits "WidgetOpened"
        end

        command "Bump" do
          reference_to Widget

          sets :count, increment: 1

          emits "WidgetBumped"
        end
      end
    end
  RUBY

  ADAPTER_PARITY_SQLITE_TARGET_HECKSAGON = <<~RUBY.freeze
    Hecks.hecksagon "QaSweepAdapterParitySqliteFixtureTarget" do
      QaSweepAdapterParitySqliteFixtureTarget::Widget.persisted_by("Memory")
    end
  RUBY

  before(:all) do
    skip "no reachable Postgres — start one to run this spec" unless PostgresProbe.available?

    @fixture_root = Dir.mktmpdir("qa_sweep_adapter_parity_sqlite_spec")
    @fixture_dir  = File.join(@fixture_root, "bluebook")
    FileUtils.mkdir_p(@fixture_dir)
    FileUtils.ln_s(File.join(InMemoryDomain::ROOT, "qa/bluebook/quality_control.bluebook"),
                   File.join(@fixture_dir, "quality_control.bluebook"))
    File.write(File.join(@fixture_dir, "quality_control.hecksagon"), LEDGER_HECKSAGON_FOR_ADAPTER_PARITY_SQLITE_SPEC)
    File.write(File.join(@fixture_dir, "quality_control.world"), <<~RUBY)
      Hecks.world "QualityControl" do
        realm "QA"
        persisted_by("PostgresEra") { database "#{QaLedgerRole.url(QA_SWEEP_ADAPTER_PARITY_SQLITE_DATABASE)}" }
      end
    RUBY

    # LIVING INSIDE THE REAL REPO ROOT, exactly `spec/qa_sweep_all_spec
    # .rb`'s own reasoning — `bin/qa_sweep` resolves a `Target`'s own
    # `path` as `File.join(ROOT, target_path)` against the real
    # repository root.
    # PREFIXED `qa-sweep-aps-target-`, DELIBERATELY NOT THE MODE'S OWN
    # FULL NAME — `Target.path`'s own basename becomes the fuzzed
    # `feature`/domain string `bin/qa_sweep` prints on every line, and a
    # prefix that itself spells out "adapter_parity_sqlite" would make
    # every assertion below that checks for the MODE NAME accidentally
    # true regardless of whether the mode actually ran (found live while
    # writing this spec: a temp-dir prefix that embedded the full mode
    # name made "stays off" pass for the wrong reason).
    @target_domain_dir = Dir.mktmpdir("qa-sweep-aps-target-", InMemoryDomain::ROOT)
    File.write(File.join(@target_domain_dir, "fixture.bluebook"), ADAPTER_PARITY_SQLITE_TARGET_BLUEBOOK)
    File.write(File.join(@target_domain_dir, "fixture.hecksagon"), ADAPTER_PARITY_SQLITE_TARGET_HECKSAGON)
    @target_domain_relpath =
      Pathname.new(@target_domain_dir).relative_path_from(Pathname.new(InMemoryDomain::ROOT)).to_s

    admin = PG.connect(dbname: "postgres")
    admin.exec("DROP DATABASE IF EXISTS #{QA_SWEEP_ADAPTER_PARITY_SQLITE_DATABASE} WITH (FORCE)")
    admin.exec("CREATE DATABASE #{QA_SWEEP_ADAPTER_PARITY_SQLITE_DATABASE}")
    admin.close
    QaLedgerRole.provision!(QA_SWEEP_ADAPTER_PARITY_SQLITE_DATABASE)
  end

  after(:all) do
    next unless PostgresProbe.available?

    admin = PG.connect(dbname: "postgres")
    admin.exec("DROP DATABASE IF EXISTS #{QA_SWEEP_ADAPTER_PARITY_SQLITE_DATABASE} WITH (FORCE)")
    admin.close
    FileUtils.remove_entry(@fixture_root)
    FileUtils.remove_entry(@target_domain_dir)
  end

  before { reset_schema! }

  def reset_schema!
    scrub = PG.connect(dbname: QA_SWEEP_ADAPTER_PARITY_SQLITE_DATABASE)
    scrub.exec("DROP SCHEMA public CASCADE")
    scrub.exec("CREATE SCHEMA public")
    scrub.close
    QaLedgerRole.own_public!(QA_SWEEP_ADAPTER_PARITY_SQLITE_DATABASE)
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

  it "folds into the ordinary sweep as its own adapter_parity_sqlite Check, on a plain, non-PostgresEra-bound target" do
    identify_target!("sqlite-parity", @target_domain_relpath)

    stdout, stderr, status = run_qa_sweep("sqlite-parity", "--modes", "ruby_only,adapter_parity_sqlite", "--seeds", "1")

    expect(status.exitstatus).to eq(0), "expected a clean sweep, got:\nSTDOUT:\n#{stdout}\nSTDERR:\n#{stderr}"
    expect(stdout).to include("resolved modes: ruby_only,adapter_parity_sqlite (capabilities=sqlite)")
    expect(stdout).to include("active modes ruby_only,adapter_parity_sqlite")
    expect(stdout).to include("seed 1: held (ruby_only, adapter_parity_sqlite)")
    expect(stdout).to include("clean — sqlite-parity concluded and released.")

    # THE LEDGER'S OWN RECORD — `check_for`'s `[mode]`-prefixed subject
    # (bin/qa_sweep's own `MODE_EXPECTATIONS`/`check_for`) is what
    # actually distinguishes this axis from `ruby_only` in the durable
    # ledger, not merely in this process's own stdout; proven here by
    # booting the same fixture ledger this sweep just wrote to and
    # reading its own `Sweep` record back — the only sweep this fresh,
    # per-example schema has ever held.
    Hecks.boot(@fixture_dir)
    sweep = QualityControl::Sweep.all.first
    expect(sweep).not_to be_nil
    subjects = sweep.checks.map { |c| c[:subject][:value] }
    expect(subjects).to include(a_string_starting_with("[adapter_parity_sqlite]"))
  end

  # THE DIAL'S OWN DEFAULT — `QualityControlDials::MODES[
  # :adapter_parity_sqlite]` is `false` (see that dial's own comment on
  # why: real, if cheap, extra I/O multiplied across the whole rotation,
  # not yet measured at rotation scale). An ORDINARY sweep, with no
  # `--modes` override, must still run exactly the checks it always did
  # — this mode existing and being wired must not silently widen every
  # sweep in the rotation until a human flips the dial.
  it "stays off an ordinary sweep — the real ledger's own dial defaults it off" do
    identify_target!("sqlite-parity-default", @target_domain_relpath)

    stdout, _stderr, status = run_qa_sweep("sqlite-parity-default", "--seeds", "1")

    expect(status.exitstatus).to eq(0)
    expect(stdout).to include("active modes ruby_only,self_consistency")
    expect(stdout).not_to include("adapter_parity_sqlite")
  end
end
