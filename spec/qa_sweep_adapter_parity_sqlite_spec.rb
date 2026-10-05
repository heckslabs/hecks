require "hecks"
require "hecks/ports/persistence/plugins/era"
require_relative "support/postgres_probe"
require_relative "support/qa_ledger_role"
require "open3"
require "hecks/quality_control/cli/child"
require "fileutils"
require "pathname"

# `qa_sweep`'s `adapter_parity_sqlite` mode, run as a real subprocess over a fixture ledger.
# Needs no PostgresEra binding: every domain has the `sqlite` capability.
RSpec.describe "qa_sweep adapter_parity_sqlite", :io do
  QA_SWEEP_ADAPTER_PARITY_SQLITE_DATABASE = "hecks_qa_sweep_adapter_parity_sqlite_spec".freeze

  # Copy of the shared fixture; top-level constants need a name no other spec file uses.
  LEDGER_HECKSAGON_FOR_ADAPTER_PARITY_SQLITE_SPEC = <<~RUBY.freeze
    Hecks::Chapters.load!("QualityControl")

    Hecks.hecksagon "QualityControl" do
      attaches "Governance"

      QualityControl::Target.persisted_by("PostgresEra")
      QualityControl::Sweep.persisted_by("PostgresEra")
      QualityControl::Bug.persisted_by("PostgresEra")
      QualityControl::Angle.persisted_by("PostgresEra")
      QualityControl::Ticket.persisted_by("PostgresEra")
      QualityControl::Patch.persisted_by("PostgresEra")
      QualityControl::Improvement.persisted_by("PostgresEra")
      QualityControl::DailyQuota.persisted_by("PostgresEra")
      QualityControl::Clearance.persisted_by("PostgresEra")
    end
  RUBY

  # Same widget as the shared fixture, bound to Memory to show no PostgresEra binding is needed.
  ADAPTER_PARITY_SQLITE_TARGET_BLUEBOOK = <<~RUBY.freeze
    Hecks.bluebook "QaSweepAdapterParitySqliteFixtureTarget" do
      vision "A trivially well-behaved sweep target, authored only to prove qa_sweep's adapter_parity_sqlite mode reaches an ordinary, non-PostgresEra-bound domain, never this repository's own live, actively-changing QA corpus."

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
    File.write(File.join(@fixture_dir, "quality_control.hecksagon"), LEDGER_HECKSAGON_FOR_ADAPTER_PARITY_SQLITE_SPEC)
    File.write(File.join(@fixture_dir, "context_map.hecksagon"), InMemoryDomain::GOVERNANCE_POSTGRES_ERA_HECKSAGON)
    url = QaLedgerRole.url(QA_SWEEP_ADAPTER_PARITY_SQLITE_DATABASE)
    File.write(File.join(@fixture_dir, "quality_control.world"), <<~RUBY)
      Hecks.world "QualityControl" do
        realm "QA"
        persisted_by("PostgresEra") { database "#{url}" }
      end
    RUBY
    File.write(File.join(@fixture_dir, "governance.world"), InMemoryDomain.governance_postgres_era_world(url))

    # Inside the repo `ROOT` because `qa_sweep` resolves a target `path` against it.
    # The prefix omits the mode name: the basename is printed, and a full name would make the
    # mode-name assertions pass whether or not the mode ran.
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
      *Hecks::QualityControlCli::Child.argv(InMemoryDomain::ROOT, "qa_sweep", *args),
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

    # `check_for`'s `[mode]`-prefixed subject tells this axis from `ruby_only` in the ledger,
    # so read the `Sweep` record back instead of trusting stdout.
    Hecks.boot(@fixture_dir)
    sweep = QualityControl::Sweep.all.first
    expect(sweep).not_to be_nil
    subjects = sweep.checks.map { |c| c[:subject][:value] }
    expect(subjects).to include(a_string_starting_with("[adapter_parity_sqlite]"))
  end
end
