require "hecks"
require "hecks/ports/persistence/plugins/era"
require_relative "support/postgres_probe"
require_relative "support/qa_ledger_role"
require "open3"
require "fileutils"
require "pathname"

# `bin/qa_sweep`'s `concurrency` mode, PROVEN AGAINST THE REAL THING —
# same discipline `spec/qa_sweep_era_boundary_spec.rb` (read that file's
# own header first) already established: a REAL `bin/qa_sweep`
# subprocess against a REAL, disposable Postgres-backed fixture LEDGER,
# sweeping a REAL, disposable, PostgresEra-bound fixture TARGET — never
# the real `hecks_quality_control` ledger, never a real corpus domain.
#
# THE MECHANISM ITSELF (the real fork, the real cross-process lock, the
# sequential oracle) IS ALREADY PROVEN in `spec/fuzzing/concurrent_
# dispatch_spec.rb`, against hand-picked step lists — this file only
# needs to prove the WIRING: the mode resolves as its own seat, is its
# own Check per seed, stays off the ordinary sweep, and — since this
# mode is expensive enough to be its own dial — respects `--modes
# concurrency` explicitly.
RSpec.describe "bin/qa_sweep concurrency", :io do
  QA_SWEEP_CONCURRENCY_LEDGER_DATABASE = "hecks_qa_sweep_concurrency_spec".freeze
  QA_SWEEP_CONCURRENCY_TARGET_DATABASE = "hecks_qa_sweep_concurrency_target_spec".freeze

  LEDGER_HECKSAGON_FOR_CONCURRENCY_SPEC = <<~RUBY.freeze
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

  # THE SAME SMALLEST DOMAIN `spec/fuzzing/concurrent_dispatch_spec.rb`'s
  # OWN fixture uses (that file's own comment: the smallest domain
  # already proven to exercise the real cross-process lock) — reused
  # rather than re-derived, as a real QA target this time.
  CONCURRENCY_TARGET_BLUEBOOK = <<~RUBY.freeze
    Hecks.bluebook "QaSweepConcurrencyFixtureTarget" do
      vision "A trivially well-behaved sweep target, authored only to prove bin/qa_sweep's concurrency mode reaches a real PostgresEra-bound domain, never this repository's own live, actively-changing QA corpus."

      aggregate "Account" do
        identified_by :number

        attribute :number,  AccountNumber
        attribute :balance, Money, default: { cents: 0 }

        value_object "AccountNumber" do
          attribute :value, String
        end

        value_object "Money" do
          attribute :cents, Integer
          invariant("a balance is never negative") { cents >= 0 }
        end

        command "Open" do
          attribute :number,  AccountNumber
          attribute :balance, Money

          sets :number
          sets :balance

          emits "AccountOpened"
        end

        command "Debit" do
          reference_to Account
          attribute :amount, Money

          given("the balance covers it") { balance.cents >= amount.cents }

          sets :balance, decrement: :amount

          emits "AccountDebited"
        end
      end
    end
  RUBY

  CONCURRENCY_TARGET_HECKSAGON = <<~RUBY.freeze
    Hecks.hecksagon "QaSweepConcurrencyFixtureTarget" do
      QaSweepConcurrencyFixtureTarget::Account.persisted_by("PostgresEra")
    end
  RUBY

  def concurrency_target_world
    <<~RUBY
      Hecks.world "QaSweepConcurrencyFixtureTarget" do
        persisted_by("PostgresEra") do
          database "postgres://localhost/#{QA_SWEEP_CONCURRENCY_TARGET_DATABASE}"
          allow_superuser true
        end
      end
    RUBY
  end

  before(:all) do
    skip "no reachable Postgres — start one to run this spec" unless PostgresProbe.available?

    @fixture_root = Dir.mktmpdir("qa_sweep_concurrency_spec")
    @fixture_dir  = File.join(@fixture_root, "bluebook")
    FileUtils.mkdir_p(@fixture_dir)
    FileUtils.ln_s(File.join(InMemoryDomain::ROOT, "qa/bluebook/quality_control.bluebook"),
                   File.join(@fixture_dir, "quality_control.bluebook"))
    File.write(File.join(@fixture_dir, "quality_control.hecksagon"), LEDGER_HECKSAGON_FOR_CONCURRENCY_SPEC)
    File.write(File.join(@fixture_dir, "quality_control.world"), <<~RUBY)
      Hecks.world "QualityControl" do
        realm "QA"
        persisted_by("PostgresEra") { database "#{QaLedgerRole.url(QA_SWEEP_CONCURRENCY_LEDGER_DATABASE)}" }
      end
    RUBY

    # PREFIXED `qa-sweep-cc-target-`, NOT THE MODE'S OWN NAME — see
    # `qa_sweep_era_boundary_spec.rb`'s identical comment for why.
    @target_domain_dir = Dir.mktmpdir("qa-sweep-cc-target-", InMemoryDomain::ROOT)
    File.write(File.join(@target_domain_dir, "fixture.bluebook"), CONCURRENCY_TARGET_BLUEBOOK)
    File.write(File.join(@target_domain_dir, "fixture.hecksagon"), CONCURRENCY_TARGET_HECKSAGON)
    File.write(File.join(@target_domain_dir, "fixture.world"), concurrency_target_world)
    @target_domain_relpath =
      Pathname.new(@target_domain_dir).relative_path_from(Pathname.new(InMemoryDomain::ROOT)).to_s

    admin = PG.connect(dbname: "postgres")
    admin.exec("DROP DATABASE IF EXISTS #{QA_SWEEP_CONCURRENCY_LEDGER_DATABASE} WITH (FORCE)")
    admin.exec("CREATE DATABASE #{QA_SWEEP_CONCURRENCY_LEDGER_DATABASE}")
    admin.exec("DROP DATABASE IF EXISTS #{QA_SWEEP_CONCURRENCY_TARGET_DATABASE} WITH (FORCE)")
    admin.exec("CREATE DATABASE #{QA_SWEEP_CONCURRENCY_TARGET_DATABASE}")
    admin.close
    QaLedgerRole.provision!(QA_SWEEP_CONCURRENCY_LEDGER_DATABASE)
  end

  after(:all) do
    next unless PostgresProbe.available?

    admin = PG.connect(dbname: "postgres")
    admin.exec("DROP DATABASE IF EXISTS #{QA_SWEEP_CONCURRENCY_LEDGER_DATABASE} WITH (FORCE)")
    admin.exec("DROP DATABASE IF EXISTS #{QA_SWEEP_CONCURRENCY_TARGET_DATABASE} WITH (FORCE)")
    admin.close
    FileUtils.remove_entry(@fixture_root)
    FileUtils.remove_entry(@target_domain_dir)
  end

  before { reset_schemas! }

  def reset_schemas!
    ledger = PG.connect(dbname: QA_SWEEP_CONCURRENCY_LEDGER_DATABASE)
    ledger.exec("DROP SCHEMA public CASCADE")
    ledger.exec("CREATE SCHEMA public")
    ledger.close
    QaLedgerRole.own_public!(QA_SWEEP_CONCURRENCY_LEDGER_DATABASE)

    target = PG.connect(dbname: QA_SWEEP_CONCURRENCY_TARGET_DATABASE)
    target.exec("SET client_min_messages = warning")
    target.exec("DROP SCHEMA public CASCADE")
    target.exec("CREATE SCHEMA public")
    target.close
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

  it "runs its own seat, one [concurrency] Check per seed, and reports clean when the real lock holds" do
    identify_target!("concurrency", @target_domain_relpath)

    stdout, stderr, status = run_qa_sweep("concurrency", "--modes", "concurrency", "--seeds", "1", "--steps", "10")

    expect(status.exitstatus).to eq(0), "expected a clean sweep, got:\nSTDOUT:\n#{stdout}\nSTDERR:\n#{stderr}"
    expect(stdout).to include("resolved modes: concurrency (capabilities=postgres_era,sqlite)")
    expect(stdout).to include("seed 1: held (concurrency)")
    expect(stdout).to include("clean — concurrency concluded and released.")

    Hecks.boot(@fixture_dir)
    sweep = QualityControl::Sweep.all.first
    expect(sweep).not_to be_nil
    subjects = sweep.checks.map { |c| c[:subject][:value] }
    expect(subjects).to include(a_string_starting_with("[concurrency]"))
  end

  # THE DIAL'S OWN DEFAULT — `QualityControlDials::MODES[:concurrency]`
  # is `false`; an ordinary sweep, with no `--modes` override, must still
  # run exactly the checks it always did.
  it "stays off an ordinary sweep — the real ledger's own dial defaults it off" do
    identify_target!("cc-default", @target_domain_relpath)

    stdout, _stderr, status = run_qa_sweep("cc-default", "--seeds", "1")

    expect(status.exitstatus).to eq(0)
    expect(stdout).not_to include("concurrency")
  end

  # `CONCURRENCY_SEED_CAP` — the SAME clamp-down discipline
  # `PERSISTENCE_PARITY_SEED_CAP` already has, proven the same way that
  # dial's own coverage is: ask for more than the cap, get exactly the
  # cap, with the note printed saying so.
  it "clamps --seeds down to QualityControlDials::CONCURRENCY_SEED_CAP" do
    identify_target!("concurrency-cap", @target_domain_relpath)

    stdout, _stderr, status = run_qa_sweep("concurrency-cap", "--modes", "concurrency", "--seeds", "50", "--steps", "5")

    expect(status.exitstatus).to eq(0)
    expect(stdout).to include("note: --seeds 50 exceeds QualityControlDials::CONCURRENCY_SEED_CAP")
    expect(stdout).to include("resolved depth: seeds=3")
    expect(stdout).to include("seed 3: held (concurrency)")
    expect(stdout).not_to include("seed 4:")
  end
end
