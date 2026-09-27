require "spec_helper"
require "hecks/ports/persistence/plugins/era"
require_relative "support/postgres_probe"
require_relative "support/qa_ledger_role"
require "tmpdir"
require "fileutils"
require "open3"

# Round trip of `bin/qa_postgres_migrate`: boots the QualityControl bluebook under a Heki
# binding, then under PostgresEra on a scratch database, both from temp-dir copies.
#
# Data is generated through real command dispatch so it matches what the ledger produces.
# Examples call `run_migrate` themselves (idempotent) because order is random; the dry-run
# result is captured in `before(:all)`, before any `--force` call.
RSpec.describe "bin/qa_postgres_migrate", :io do
  # A constant assigned in a describe block lands at top level, and
  # spec/oidc_manifest_spec.rb already owns the bare name `ROOT`.
  BLUEBOOK_SOURCE  = File.join(InMemoryDomain::ROOT, "qa/bluebook/quality_control.bluebook")
  HECKSAGON_SOURCE = File.join(InMemoryDomain::ROOT, "qa/bluebook/quality_control.hecksagon")
  MIGRATE_SCRIPT   = File.join(InMemoryDomain::ROOT, "bin/qa_postgres_migrate")
  SCRATCH_DB       = "hecks_qa_migration_spec".freeze

  # Heki-backed wiring, inlined so it stays fixed whatever the real file says. Same as the
  # real hecksagon except for the seven `persisted_by` lines.
  HEKI_HECKSAGON = <<~HECKSAGON.freeze
    Hecks.hecksagon "QualityControl" do
      uses_framework "Governance"

      QualityControl::Target.persisted_by("Heki")
      QualityControl::Sweep.persisted_by("Heki")
      QualityControl::Bug.persisted_by("Heki")
      QualityControl::Angle.persisted_by("Heki")
      QualityControl::Ticket.persisted_by("Heki")
      QualityControl::Patch.persisted_by("Heki")
      QualityControl::Clearance.persisted_by("Heki")

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
  HECKSAGON

  def canonical(value)
    case value
    when Hash
      value.each_with_object({}) { |(k, v), h| h[k.to_s] = canonical(v) }.sort.to_h
    when Array
      value.map { |v| canonical(v) }
    else
      value
    end
  end

  def run_migrate(*args)
    Open3.capture3("ruby", MIGRATE_SCRIPT, @pg_dir, @heki_data_dir, *args)
  end

  before(:all) do
    skip "no reachable Postgres — start one to run this spec" unless PostgresProbe.available?

    @tmp = Dir.mktmpdir("qa_pg_migrate_spec")
    heki_bluebook_dir = File.join(@tmp, "heki_boot/bluebook")
    @pg_dir           = File.join(@tmp, "pg_boot/bluebook")
    @heki_data_dir    = File.join(@tmp, "heki_boot/data")
    FileUtils.mkdir_p(heki_bluebook_dir)
    FileUtils.mkdir_p(@pg_dir)

    FileUtils.cp(BLUEBOOK_SOURCE, heki_bluebook_dir)
    FileUtils.cp(BLUEBOOK_SOURCE, @pg_dir)
    FileUtils.cp(HECKSAGON_SOURCE, @pg_dir)
    File.write(File.join(heki_bluebook_dir, "quality_control.hecksagon"), HEKI_HECKSAGON)
    File.write(File.join(heki_bluebook_dir, "context_map.hecksagon"), InMemoryDomain::GOVERNANCE_MEMORY_HECKSAGON)
    File.write(File.join(@pg_dir, "context_map.hecksagon"), InMemoryDomain::GOVERNANCE_POSTGRES_ERA_HECKSAGON)
    url = QaLedgerRole.url(SCRATCH_DB)
    File.write(File.join(@pg_dir, "quality_control.world"), <<~WORLD)
      Hecks.world "QualityControl" do
        realm "QA"
        persisted_by("PostgresEra") do
          database "#{url}"
        end
      end
    WORLD
    File.write(File.join(@pg_dir, "governance.world"), InMemoryDomain.governance_postgres_era_world(url))

    admin = PG.connect(dbname: "postgres")
    admin.exec("DROP DATABASE IF EXISTS #{SCRATCH_DB} WITH (FORCE)")
    admin.exec("CREATE DATABASE #{SCRATCH_DB}")
    admin.close
    # Same URL shape and `bin/qa_postgres_role` step as the real ledger's `.world`.
    QaLedgerRole.provision!(SCRATCH_DB)

    @heki_runtime = Hecks.boot(heki_bluebook_dir)

    t1 = QualityControl::Target.identify!(reference: { value: "banking" }, path: { value: "examples/banking" })
    t1.claim!(held_by: { value: "agent-one" }, now: { value: 1_000 })
    t1.release!(now: { value: 1_500 }, yield_score: { value: 0 }, next_streak: { value: 1 },
                capabilities: { value: "rust" })
    t1.claim!(held_by: { value: "agent-two" }, now: { value: 1_600 })

    t2 = QualityControl::Target.identify!(reference: { value: "pizzas" }, path: { value: "examples/pizzas" })
    t2.shelve!(reason: { value: "already fully covered by chess parity work" })

    t3 = QualityControl::Target.identify!(reference: { value: "chess" }, path: { value: "examples/chess" })

    sweep = QualityControl::Sweep.open!(target: t1.id, reference: { value: "SW-1" }, engineer: { value: "Claude QA" })
    25.times do |i|
      n = i + 1
      freeze_expectation = "a frozen account refuses a second freeze, check #{n}"
      @heki_runtime.dispatch_flat("QualityControl::Sweep.Check", id:          sweep.id,
                                                                 subject:     { value: "Banking::Account.Freeze##{n}" },
                                                                 expectation: { value: freeze_expectation })
      if n.even?
        @heki_runtime.dispatch_flat("QualityControl::Sweep.Check.Held", id: sweep.id,
                                sequence: { value: n }, observation: { value: "refused as expected, check #{n}" })
      else
        @heki_runtime.dispatch_flat("QualityControl::Sweep.Check.Surprised", id: sweep.id,
                                sequence: { value: n }, observation: { value: "silently accepted, check #{n}" },
                                target: { value: t1.id })
      end
    end
    sweep.conclude!(notes: { value: "found several surprising divergences in the freeze/unfreeze cycle" })

    sweep2 = QualityControl::Sweep.open!(target: t3.id, reference: { value: "SW-2" }, engineer: { value: "Claude QA 2" })
    sweep2.waive!(reason:    { value: "the chapter would not boot; recording the pass so the rotation moves on" },
                  waived_by: { value: "Claude QA 2" })
    sweep2.conclude!(notes: { value: "boot refused outright; nothing could be checked this pass" })

    bug = QualityControl::Bug.log!(
      sweep: sweep.id, reference: { value: "BUG#1" }, sequence: { value: 1 },
      title: { value: "as: is accepted and does not alias" },
      demonstration: { value: 'rspec spec/qa_bugs_spec.rb -e "aliasing"' },
      symptom: { value: "the alias is ignored and the original name still answers" },
      expectation: { value: "the aliased name answers and the original does not" },
      submitter: { value: "Claude QA" }
    )
    bug.tag!(tags: [{ value: "framework" }, { value: "silent-divergence" }, { value: "as-alias" }])
    bug.investigate!(site: { value: "lib/hecks/runtime/routing.rb:88" }, cause: { value: "as: is parsed and discarded" })
    bug.fix!(reference: { value: "BUG#1" }, commit: { value: "4f2a19cabc1234deadbeef00112233445566" })
    bug.verify!(evidence: { value: "rspec --order random: 1335 examples, 0 failures, seed 12345" })
    bug.rank!(order: { value: 5 })

    bug2 = QualityControl::Bug.log!(
      sweep: sweep.id, reference: { value: "BUG#2" }, sequence: { value: 2 },
      title: { value: "second bug, still open" },
      demonstration: { value: "spec/x_spec.rb" },
      symptom: { value: "s" }, expectation: { value: "e" },
      submitter: { value: "Claude QA" }, tags: [{ value: "flaky" }]
    )
    bug2.pause!(reason: { value: "affects the whole type system" }, next_step: { value: "architecture review" })

    angle = QualityControl::Angle.propose!(
      reference: { value: "ANGLE-1" }, proposer: { value: "Claude QA" },
      premise: { value: "Nobody has fuzzed entity-list-under-era-migration before, and BUG#1 suggests it's ripe." },
      citation: { value: "BUG#1" }, now: { value: 1_000 }
    )
    angle.investigate!
    angle.build!(resolution: { value: "built into bin/qa_postgres_migrate + this spec" })

    QualityControl::Angle.propose!(
      reference: { value: "ANGLE-2" }, proposer: { value: "Claude QA" },
      premise: { value: "Whether list_of value objects round-trip identically through PostgresEra jsonb storage." },
      citation: { value: "ADR 0036" }, now: { value: 1_100 }
    )

    c1 = QualityControl::Clearance.start!(commit: { value: "4f2a19cabc1234deadbeef00112233445566" })
    c1.passed!(summary: { value: "1335 examples, 0 failures, seed 12345" })

    c2 = QualityControl::Clearance.start!(commit: { value: "deadbee0000000000000000000000000000" })
    c2.failed!(refusal: { value: "1335 examples, 3 failures, seed 999" })

    QualityControl::Ticket.raise!(
      bug: bug2.id, reference: { value: "TK-1" },
      repository: { value: "org/hecks" }, title: { value: "second bug, still open" },
      body: { value: "see BUG#2 in the QA ledger" }
    )

    # Dry run first: before any --force call has written a row.
    @dry_run_stdout, @dry_run_stderr, @dry_run_status = run_migrate
    @dry_run_pg_rows = Hecks.boot(@pg_dir).query("QualityControl::Target.All")
  end

  after(:all) do
    next unless PostgresProbe.available?

    admin = PG.connect(dbname: "postgres")
    admin.exec("DROP DATABASE IF EXISTS #{SCRATCH_DB} WITH (FORCE)")
    admin.close
    FileUtils.remove_entry(@tmp) if @tmp
  end

  QUERIES = %w[Target.All Sweep.All Bug.All Angle.All Clearance.All Ticket.All
               Angle.Backlog Target.Rotation Sweep.Waived Sweep.Check.Surprising].freeze

  it "dry-runs without writing anything, and reports every id it would migrate" do
    expect(@dry_run_status.exitstatus).to eq(0)
    expect(@dry_run_stderr).to eq("")
    expect(@dry_run_stdout).to include("WOULD MIGRATE target/banking")
    expect(@dry_run_stdout).to include("WOULD MIGRATE sweep/SW-1")
    expect(@dry_run_stdout).to include("would migrate 12, skipped 0")

    expect(@dry_run_pg_rows).to be_empty
  end

  it "migrates every record faithfully with --force, byte-for-byte equal to the Heki source" do
    _out, _err, status = run_migrate("--force")
    expect(status.exitstatus).to eq(0)

    pg_runtime = Hecks.boot(@pg_dir)

    QUERIES.each do |query|
      heki_rows = @heki_runtime.query("QualityControl::#{query}")
      pg_rows   = pg_runtime.query("QualityControl::#{query}")

      expect(pg_rows.map { |r| canonical(r) }).to eq(heki_rows.map { |r| canonical(r) }), "#{query} diverged"
      expect(pg_rows).not_to be_empty
    end

    # All 25 checks come back, in the order they were made.
    sweep_row = pg_runtime.query("QualityControl::Sweep.All").find { |r| r[:reference][:value] == "SW-1" }
    expect(sweep_row[:checks].length).to eq(25)
    expect(sweep_row[:checks].map { |c| c[:sequence][:value] }).to eq((1..25).to_a)

    bug_row = pg_runtime.query("QualityControl::Bug.All").find { |r| r[:reference][:value] == "BUG#1" }
    expect(bug_row[:tags].map { |t| t[:value] }.sort).to eq(%w[as-alias framework silent-divergence])

    # Logged, Investigated, Fixed, then Verified must not regress to the initial state.
    expect(bug_row[:status]).to eq("verified")
  end

  it "is idempotent — a second --force run skips everything already caught up, writes nothing new" do
    run_migrate("--force")
    out, _err, status = run_migrate("--force")

    expect(status.exitstatus).to eq(0)
    expect(out).to include("migrated 0, skipped 12 (already caught up), refused 0")
  end

  it "refuses (never overwrites) an id whose destination state genuinely conflicts" do
    run_migrate("--force")

    pg_runtime = Hecks.boot(@pg_dir)
    registry   = pg_runtime.registry
    aggregate  = registry.bluebook("QualityControl").aggregate("Target")
    repo       = registry.repository("QualityControl", aggregate)

    original = repo.find("pizzas")
    mutated_state = original.state.dup
    mutated_state[:reason] = { value: "DELIBERATELY MUTATED FOR CONFLICT TEST" }
    repo.save(Hecks::Runtime::Instance.new(aggregate: aggregate, id: "pizzas", state: mutated_state))

    out, err, status = run_migrate("--force")

    expect(status.exitstatus).to eq(1)
    # The refusal goes to stderr, the summary to stdout.
    expect(err).to include("REFUSED target/pizzas")
    expect(out).to include("refused 1 (conflicting data)")

    # The mutation must survive: refusing means not overwriting.
    still_mutated = repo.find("pizzas")
    expect(still_mutated.state[:reason].to_h).to eq({ value: "DELIBERATELY MUTATED FOR CONFLICT TEST" })
  ensure
    # Restore: other examples share the scratch database and run in random order.
    if defined?(repo) && repo && defined?(original) && original
      repo.save(Hecks::Runtime::Instance.new(aggregate: aggregate, id: "pizzas", state: original.state))
    end
  end

  it "never touches the source Heki files" do
    heki_target_path = File.join(@heki_data_dir, "target.heki")
    before_bytes = File.read(heki_target_path)

    run_migrate("--force")

    expect(File.read(heki_target_path)).to eq(before_bytes)
  end
end
