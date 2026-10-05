require "open3"
require "hecks/quality_control/cli/child"
require "tempfile"
require "fileutils"
require "pathname"
require_relative "postgres_probe"
require_relative "qa_ledger_role"

# Shared fixture for the `qa_sweep --all` specs; pass a per-file unique database name.
# Files run as concurrent processes, so a shared name would race on create/drop.
RSpec.shared_context "with a qa_sweep_all fixture" do |database_name|
  # Guarded with `unless defined?`: this block is re-evaluated per `include_context`, and the
  # constants bind at top level. Fixture crate: standalone, outside `rust/`'s workspace, and its
  # binary always answers a fixed mismatch.
  unless defined?(FIXTURE_RUST_DIR)
    FIXTURE_RUST_DIR = File.join(InMemoryDomain::ROOT,
                                 "spec/fixtures/qa_sweep_all_found_fixture_rust").freeze
  end

  # The fixture ledger's `.hecksagon`: quality_control.hecksagon, chapter ports included.
  FIXTURE_HECKSAGON = <<~RUBY.freeze unless defined?(FIXTURE_HECKSAGON)
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

  # Two concurrent processes race the same `Target.claim!`; the loser prints "refused" and exits 1.
  CLAIM_RACE_SCRIPT = <<~RUBY.freeze unless defined?(CLAIM_RACE_SCRIPT)
    root, domain_dir, target_ref, engineer = ARGV
    $LOAD_PATH.unshift File.join(root, "lib")
    require "hecks"
    require "hecks/ports/persistence/plugins/era"

    Hecks.boot(domain_dir)
    target = QualityControl::Target.find(target_ref)

    begin
      target.claim!(held_by: { value: engineer }, now: { value: Time.now.to_i })
      puts "claimed"
      exit 0
    rescue Hecks::Runtime::GivenNotMet
      puts "refused"
      exit 1
    end
  RUBY

  # A trivial target no fuzzer can violate, so "clean" examples never depend on the live corpus.
  # No Rust feature, so `qa_sweep` runs it `ruby_only`.
  FIXTURE_TARGET_BLUEBOOK = <<~RUBY.freeze unless defined?(FIXTURE_TARGET_BLUEBOOK)
    Hecks.bluebook "QaSweepAllFixtureTarget" do
      vision "A trivially well-behaved sweep target, authored only so this spec's own 'clean' examples never depend on this repository's own live, actively-changing QA corpus."

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

  FIXTURE_TARGET_HECKSAGON = <<~RUBY.freeze unless defined?(FIXTURE_TARGET_HECKSAGON)
    Hecks.hecksagon "QaSweepAllFixtureTarget" do
      QaSweepAllFixtureTarget::Widget.persisted_by("Heki")
    end
  RUBY

  # The same target bound to PostgresEra, which makes it eligible for `persistence_parity`.
  FIXTURE_PG_TARGET_HECKSAGON = <<~RUBY.freeze unless defined?(FIXTURE_PG_TARGET_HECKSAGON)
    Hecks.hecksagon "QaSweepAllFixtureTarget" do
      QaSweepAllFixtureTarget::Widget.persisted_by("PostgresEra")
    end
  RUBY

  before(:all) do
    skip "no reachable Postgres — start one to run this spec" unless PostgresProbe.available?

    @qa_sweep_all_database = database_name

    @fixture_root = Dir.mktmpdir("qa_sweep_all_spec")
    @fixture_dir  = File.join(@fixture_root, "bluebook")
    FileUtils.mkdir_p(@fixture_dir)
    File.write(File.join(@fixture_dir, "quality_control.hecksagon"), FIXTURE_HECKSAGON)
    File.write(File.join(@fixture_dir, "context_map.hecksagon"), InMemoryDomain::GOVERNANCE_POSTGRES_ERA_HECKSAGON)
    # Same URL shape as the real ledger; PostgresEra refuses to boot as the ambient superuser.
    url = QaLedgerRole.url(@qa_sweep_all_database)
    File.write(File.join(@fixture_dir, "quality_control.world"), <<~RUBY)
      Hecks.world "QualityControl" do
        realm "QA"
        persisted_by("PostgresEra") { database "#{url}" }
      end
    RUBY
    File.write(File.join(@fixture_dir, "governance.world"), InMemoryDomain.governance_postgres_era_world(url))

    # Inside the repo root because `qa_sweep` resolves a target's path against it.
    @target_domain_dir = Dir.mktmpdir("qa_sweep_all_spec_target-", InMemoryDomain::ROOT)
    File.write(File.join(@target_domain_dir, "fixture.bluebook"), FIXTURE_TARGET_BLUEBOOK)
    File.write(File.join(@target_domain_dir, "fixture.hecksagon"), FIXTURE_TARGET_HECKSAGON)
    @target_domain_relpath = Pathname.new(@target_domain_dir).relative_path_from(Pathname.new(InMemoryDomain::ROOT)).to_s

    @pg_target_domain_dir = Dir.mktmpdir("qa_sweep_all_spec_pg_target-", InMemoryDomain::ROOT)
    File.write(File.join(@pg_target_domain_dir, "fixture.bluebook"), FIXTURE_TARGET_BLUEBOOK)
    File.write(File.join(@pg_target_domain_dir, "fixture.hecksagon"), FIXTURE_PG_TARGET_HECKSAGON)
    @pg_target_domain_relpath =
      Pathname.new(@pg_target_domain_dir).relative_path_from(Pathname.new(InMemoryDomain::ROOT)).to_s

    admin = PG.connect(dbname: "postgres")
    admin.exec("DROP DATABASE IF EXISTS #{@qa_sweep_all_database} WITH (FORCE)")
    admin.exec("CREATE DATABASE #{@qa_sweep_all_database}")
    admin.close
    @role_report = QaLedgerRole.provision!(@qa_sweep_all_database)
  end

  after(:all) do
    next unless PostgresProbe.available?

    admin = PG.connect(dbname: "postgres")
    admin.exec("DROP DATABASE IF EXISTS #{@qa_sweep_all_database} WITH (FORCE)")
    admin.close
    FileUtils.remove_entry(@fixture_root)
    FileUtils.remove_entry(@target_domain_dir)
    FileUtils.remove_entry(@pg_target_domain_dir)
  end

  # Fresh schema per example so no Sweep, Bug or Target row leaks into the next rotation.
  before { reset_schema! }

  # Resets the fixture database's `public` schema to empty, owned by the QA role.
  def reset_schema!
    scrub = PG.connect(dbname: @qa_sweep_all_database)
    scrub.exec("DROP SCHEMA public CASCADE")
    scrub.exec("CREATE SCHEMA public")
    scrub.close
    QaLedgerRole.own_public!(@qa_sweep_all_database)
  end

  # Boots in-process only to write `Target` rows; sweeps run as separate `qa_sweep` processes.
  def identify_targets!(targets)
    Hecks.boot(@fixture_dir)
    targets.each do |reference, path|
      QualityControl::Target.identify!(reference: { value: reference }, path: { value: path })
    end
  end

  # Runs `qa_sweep` as a real subprocess against the fixture ledger and fixture Rust crate.
  # `env` merges in on top of the fixture's own two vars — for example
  # QA_SWEEP_COVERAGE_CORPUS_DIR, so a spec can point coverage-guided generation's corpus at its
  # own throwaway directory instead of this repository's real tmp/qa-coverage-corpus.
  def run_qa_sweep(*args, env: {})
    Open3.capture3(
      { "QA_SWEEP_DOMAIN_DIR" => @fixture_dir, "QA_SWEEP_RUST_DIR" => FIXTURE_RUST_DIR }.merge(env),
      *Hecks::QualityControlCli::Child.argv(InMemoryDomain::ROOT, "qa_sweep", *args),
      chdir: InMemoryDomain::ROOT
    )
  end

  # Polls with `waitpid2(WNOHANG)`, not `Process.kill(0, pid)`: a zombie answers kill(0) like a live
  # process. Calls the block once per poll; returns `[status, probe_results]`.
  def reap_while_polling(pid)
    results = []
    loop do
      reaped_pid, status = Process.waitpid2(pid, Process::WNOHANG)
      return [status, results] if reaped_pid

      results << yield
      sleep 0.2
    end
  end
end
