require "open3"
require "tempfile"
require "fileutils"
require "pathname"
require_relative "postgres_probe"
require_relative "qa_ledger_role"

# THE `bin/qa_sweep --all` FIXTURE, SHARED — extracted from what used to
# be one 710-line `qa_sweep_all_spec.rb` (Phase 2 of the CI speed
# effort): the file's own 13 examples took 336s together on one CI
# runner, a floor no matrix size could split further since
# `parallel_rspec` balances at file granularity. Splitting the FIXTURE
# out here and the 13 examples across several small files (each
# `include_context "with a qa_sweep_all fixture", <unique database name>`) lets
# the shard balancer actually spread this file's own work instead of
# being stuck with one 336s lump.
#
# PARAMETERIZED BY DATABASE NAME, NOT HARDCODED — every file that
# includes this context passes its OWN throwaway Postgres database name
# (`include_context "with a qa_sweep_all fixture", "hecks_qa_sweep_all_foo_spec"`).
# `parallel_rspec` runs different FILES as genuinely concurrent OS
# processes, so two files sharing one database name would race each
# other's own `CREATE DATABASE`/`DROP SCHEMA CASCADE` — the exact
# per-file-unique-resource-name discipline ci.yml's own
# `rspec_postgres_io_parallel_shard` header already requires of every
# `io: true` spec. Stored as `@qa_sweep_all_database` (an instance
# variable, not the block's own `database_name` local) so it is visible
# both to instance methods defined here (`def`, not `before { }`, has its
# own scope and cannot see a block-local) and to `it` blocks in the
# including file.
#
# See `qa_sweep_all_spec.rb`'s own former header (still present, in
# whichever split file was first to keep it) for the full "why a
# disposable ledger, not the real one" / "why QA_SWEEP_DOMAIN_DIR" reasoning
# this fixture rests on — not repeated here to avoid every split file
# duplicating it.
RSpec.shared_context "with a qa_sweep_all fixture" do |database_name|
  # THE "FOUND SOMETHING" EXAMPLE'S OWN FIXTURE CRATE — a small
  # STANDALONE Rust crate (own `Cargo.toml`, `spec/fixtures/qa_sweep_all_
  # found_fixture_rust/`, deliberately outside `rust/`'s own workspace/
  # feature list) whose compiled binary always answers a fixed,
  # hand-written mismatch against `spec/fixtures/qa_sweep_all_found_
  # fixture`'s own trivially well-behaved Ruby domain.
  FIXTURE_RUST_DIR = File.join(InMemoryDomain::ROOT, "spec/fixtures/qa_sweep_all_found_fixture_rust").freeze

  # THE FIXTURE LEDGER'S OWN `.hecksagon` — line-for-line what
  # `qa/bluebook/quality_control.hecksagon` declares (every aggregate
  # `persisted_by("PostgresEra")`, the same two dormant/bound ports),
  # EXCEPT it binds no adapter for the `CI` port at all — see the
  # original file's own comment (preserved in git history) for why an
  # unbound `CI` port here is harmless.
  FIXTURE_HECKSAGON = <<~RUBY.freeze
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

  # ONE STANDALONE SCRIPT, RUN AS TWO REAL CONCURRENT PROCESSES — the
  # mechanism `--all`'s own "no extra lock needed" claim rests on,
  # exercised directly: two racers dispatch the exact same
  # `QualityControl::Target.claim!`, both against the SAME target
  # reference, and whichever loses prints "refused" and exits 1.
  CLAIM_RACE_SCRIPT = <<~RUBY.freeze
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

  # A DELIBERATELY TRIVIAL, SELF-AUTHORED SWEEP TARGET — one aggregate,
  # two commands, no invariant a random fuzzer could ever find a way to
  # violate, so a "clean" example never depends on this repository's own
  # actively-changing live QA corpus. No Rust feature, so `bin/qa_sweep`
  # always runs it in `ruby_only` mode.
  FIXTURE_TARGET_BLUEBOOK = <<~RUBY.freeze
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

  FIXTURE_TARGET_HECKSAGON = <<~RUBY.freeze
    Hecks.hecksagon "QaSweepAllFixtureTarget" do
      QaSweepAllFixtureTarget::Widget.persisted_by("Heki")
    end
  RUBY

  # THE SAME TRIVIAL TARGET, BOUND TO PostgresEra — the one capability
  # `Hecks::Fuzzing::TargetCapabilities` reads off a `.hecksagon` to make
  # a target eligible for `persistence_parity`, and therefore for
  # `--all`'s own second wave.
  FIXTURE_PG_TARGET_HECKSAGON = <<~RUBY.freeze
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
    FileUtils.ln_s(File.join(InMemoryDomain::ROOT, "qa/bluebook/quality_control.bluebook"),
                   File.join(@fixture_dir, "quality_control.bluebook"))
    File.write(File.join(@fixture_dir, "quality_control.hecksagon"), FIXTURE_HECKSAGON)
    # THE SAME URL SHAPE THE REAL LEDGER BINDS: the database by URL, as
    # `hecks_qa`, an ordinary owner role — PostgresEra refuses to boot as
    # the ambient superuser (BUG#24). `bin/qa_postgres_role`, run for
    # real below, is what makes it connectable.
    File.write(File.join(@fixture_dir, "quality_control.world"), <<~RUBY)
      Hecks.world "QualityControl" do
        realm "QA"
        persisted_by("PostgresEra") { database "#{QaLedgerRole.url(@qa_sweep_all_database)}" }
      end
    RUBY

    # LIVING INSIDE THE REAL REPO ROOT, NOT `/tmp` — `bin/qa_sweep`
    # always resolves a `Target`'s own `path` against the REAL repository
    # root, independent of `QA_SWEEP_DOMAIN_DIR`.
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

  # A FRESH SCHEMA BEFORE EVERY EXAMPLE — a Sweep, Bug or Target row a
  # PRIOR example claimed/concluded/left held must never leak into the
  # next one's own rotation.
  before { reset_schema! }

  def reset_schema!
    scrub = PG.connect(dbname: @qa_sweep_all_database)
    scrub.exec("DROP SCHEMA public CASCADE")
    scrub.exec("CREATE SCHEMA public")
    scrub.close
    QaLedgerRole.own_public!(@qa_sweep_all_database)
  end

  # Booted IN-PROCESS, briefly, purely to write `Target` rows down —
  # never to dispatch a sweep itself (every sweep in this file runs as a
  # real, separate `bin/qa_sweep` process, which is the whole point).
  def identify_targets!(targets)
    Hecks.boot(@fixture_dir)
    targets.each do |reference, path|
      QualityControl::Target.identify!(reference: { value: reference }, path: { value: path })
    end
  end

  # THE EXACT INVOCATION a human (or `--all`'s own children) would type,
  # run for real via `Open3.capture3` — `QA_SWEEP_DOMAIN_DIR` is what
  # tells it to use this spec's own fixture ledger instead of the real
  # one, and `QA_SWEEP_RUST_DIR` is what tells `found_one`'s own
  # differential diff to build/run this spec's own hand-maintained
  # fixture crate rather than reaching for the real `rust/`.
  def run_qa_sweep(*args)
    Open3.capture3(
      { "QA_SWEEP_DOMAIN_DIR" => @fixture_dir, "QA_SWEEP_RUST_DIR" => FIXTURE_RUST_DIR },
      "bundle", "exec", "ruby", File.join(InMemoryDomain::ROOT, "bin/qa_sweep"), *args,
      chdir: InMemoryDomain::ROOT
    )
  end

  def process_alive?(pid)
    Process.kill(0, pid)
    true
  rescue Errno::ESRCH
    false
  end

  # THE NON-BLOCKING REAP LOOP — see the `keeps at most SWEEP_MAX_PARALLEL`
  # example's own comment (wherever that example landed) for why this is
  # `Process.waitpid2(pid, Process::WNOHANG)`, polled, and NOT
  # `process_alive?` in a loop (a zombie answers `process_alive?` just as
  # a live process would, so that loop can never observe the child
  # exiting). `probe` is called once per poll and returns whatever this
  # run wants tracked; returns `[status, probe_results]`.
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
