require "hecks"
require "hecks/ports/persistence/plugins/era"
require_relative "support/postgres_probe"
require_relative "support/qa_ledger_role"
require "open3"
require "fileutils"
require "pathname"

# `bin/qa_sweep`'s `era_boundary` mode, PROVEN AGAINST THE REAL THING —
# same discipline `spec/qa_sweep_adapter_parity_sqlite_spec.rb` (read
# that file's own header first) already established: a REAL `bin/qa_sweep`
# subprocess against a REAL, disposable Postgres-backed fixture LEDGER,
# sweeping a REAL, disposable, PostgresEra-bound fixture TARGET — never
# the real `hecks_quality_control` ledger, never a real corpus domain.
#
# SEEDLESS, UNLIKE EVERY SIBLING MODE SPEC — `era_boundary` never
# generates a sequence (`Hecks::Fuzzing::EraBoundary`'s own header, and
# `bin/qa_sweep`'s own `SEEDLESS_MODES`), so this spec proves the mode
# resolves, runs exactly once per sweep regardless of `--seeds`, and
# reports clean on a target that has never diverged — the finding-side
# arithmetic itself (a real post-cut write actually surfacing) is already
# proven, at the module level, in `spec/fuzzing/era_boundary_spec.rb`;
# this file only needs to prove the WIRING reaches it.
RSpec.describe "bin/qa_sweep era_boundary", :io do
  QA_SWEEP_ERA_BOUNDARY_LEDGER_DATABASE = "hecks_qa_sweep_era_boundary_spec".freeze
  QA_SWEEP_ERA_BOUNDARY_TARGET_DATABASE = "hecks_qa_sweep_era_boundary_target_spec".freeze

  LEDGER_HECKSAGON_FOR_ERA_BOUNDARY_SPEC = <<~RUBY.freeze
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

  # A REAL PostgresEra-BOUND TARGET, WITH A REAL `translations/` FILE —
  # `MODE_REQUIREMENTS[:era_boundary]` (target_capabilities.rb) gates
  # eligibility on BOTH capabilities, so this fixture needs one of each:
  # the binding, and a `translations/*.bluebook` file present on disk
  # (its own CONTENT never matters to `Hecks::Fuzzing::EraBoundary` — that
  # module only ever reads `hecks_eras`/the journal directly, never the
  # translation edge itself — confirmed live while writing this spec: a
  # harmless self-rename edge with fabricated era-hash labels that never
  # match anything real loads and boots without complaint).
  ERA_BOUNDARY_TARGET_BLUEBOOK = <<~RUBY.freeze
    Hecks.bluebook "QaSweepEraBoundaryFixtureTarget" do
      vision "A trivially well-behaved sweep target, authored only to prove bin/qa_sweep's era_boundary mode reaches a real PostgresEra-bound domain, never this repository's own live, actively-changing QA corpus."

      aggregate "Widget" do
        description "One numbered widget — nothing a fuzzer can ever catch."

        identified_by :reference

        attribute :reference, WidgetReference

        value_object "WidgetReference" do
          attribute :value, String, pattern: '[^ \\t\\n\\r]'
          invariant("a widget is referenced") { !value.to_s.empty? }
        end

        command "Open" do
          attribute :reference, WidgetReference

          sets :reference

          emits "WidgetOpened"
        end
      end
    end
  RUBY

  ERA_BOUNDARY_TARGET_HECKSAGON = <<~RUBY.freeze
    Hecks.hecksagon "QaSweepEraBoundaryFixtureTarget" do
      QaSweepEraBoundaryFixtureTarget::Widget.persisted_by("PostgresEra")
    end
  RUBY

  # `allow_superuser true` — THE SAME OPT-IN `examples/directory.world`
  # ITSELF USES, not the fenced `QaLedgerRole` dance the LEDGER fixture
  # needs: this target's own real database is disposable and owned
  # outright by whatever role runs this spec, and `era_boundary` never
  # exercises the write-fence at all (it only ever reads).
  def era_boundary_target_world
    <<~RUBY
      Hecks.world "QaSweepEraBoundaryFixtureTarget" do
        persisted_by("PostgresEra") do
          database "postgres://localhost/#{QA_SWEEP_ERA_BOUNDARY_TARGET_DATABASE}"
          allow_superuser true
        end
      end
    RUBY
  end

  ERA_BOUNDARY_TARGET_TRANSLATION_EDGE = <<~RUBY.freeze
    Hecks.data_translation("QaSweepEraBoundaryFixtureTarget", from: "aaaaaaaa", to: "bbbbbbbb") do
      aggregate("Widget") do
        rename :reference, to: :reference
      end
    end
  RUBY

  before(:all) do
    skip "no reachable Postgres — start one to run this spec" unless PostgresProbe.available?

    @fixture_root = Dir.mktmpdir("qa_sweep_era_boundary_spec")
    @fixture_dir  = File.join(@fixture_root, "bluebook")
    FileUtils.mkdir_p(@fixture_dir)
    FileUtils.ln_s(File.join(InMemoryDomain::ROOT, "qa/bluebook/quality_control.bluebook"),
                   File.join(@fixture_dir, "quality_control.bluebook"))
    File.write(File.join(@fixture_dir, "quality_control.hecksagon"), LEDGER_HECKSAGON_FOR_ERA_BOUNDARY_SPEC)
    File.write(File.join(@fixture_dir, "quality_control.world"), <<~RUBY)
      Hecks.world "QualityControl" do
        realm "QA"
        persisted_by("PostgresEra") { database "#{QaLedgerRole.url(QA_SWEEP_ERA_BOUNDARY_LEDGER_DATABASE)}" }
      end
    RUBY

    # PREFIXED `qa-sweep-eb-target-`, NOT THE MODE'S OWN NAME — the exact
    # same reason `qa_sweep_adapter_parity_sqlite_spec.rb`'s own comment
    # gives: `Target.path`'s basename becomes the fuzzed `feature` string
    # bin/qa_sweep prints on every line, and a prefix spelling out
    # "era_boundary" would make an assertion that greps stdout for that
    # name accidentally true regardless of whether the mode actually ran.
    @target_domain_dir = Dir.mktmpdir("qa-sweep-eb-target-", InMemoryDomain::ROOT)
    File.write(File.join(@target_domain_dir, "fixture.bluebook"), ERA_BOUNDARY_TARGET_BLUEBOOK)
    File.write(File.join(@target_domain_dir, "fixture.hecksagon"), ERA_BOUNDARY_TARGET_HECKSAGON)
    File.write(File.join(@target_domain_dir, "fixture.world"), era_boundary_target_world)
    FileUtils.mkdir_p(File.join(@target_domain_dir, "translations"))
    File.write(File.join(@target_domain_dir, "translations", "1-fake.bluebook"), ERA_BOUNDARY_TARGET_TRANSLATION_EDGE)
    @target_domain_relpath =
      Pathname.new(@target_domain_dir).relative_path_from(Pathname.new(InMemoryDomain::ROOT)).to_s

    admin = PG.connect(dbname: "postgres")
    admin.exec("DROP DATABASE IF EXISTS #{QA_SWEEP_ERA_BOUNDARY_LEDGER_DATABASE} WITH (FORCE)")
    admin.exec("CREATE DATABASE #{QA_SWEEP_ERA_BOUNDARY_LEDGER_DATABASE}")
    admin.exec("DROP DATABASE IF EXISTS #{QA_SWEEP_ERA_BOUNDARY_TARGET_DATABASE} WITH (FORCE)")
    admin.exec("CREATE DATABASE #{QA_SWEEP_ERA_BOUNDARY_TARGET_DATABASE}")
    admin.close
    QaLedgerRole.provision!(QA_SWEEP_ERA_BOUNDARY_LEDGER_DATABASE)
  end

  after(:all) do
    next unless PostgresProbe.available?

    admin = PG.connect(dbname: "postgres")
    admin.exec("DROP DATABASE IF EXISTS #{QA_SWEEP_ERA_BOUNDARY_LEDGER_DATABASE} WITH (FORCE)")
    admin.exec("DROP DATABASE IF EXISTS #{QA_SWEEP_ERA_BOUNDARY_TARGET_DATABASE} WITH (FORCE)")
    admin.close
    FileUtils.remove_entry(@fixture_root)
    FileUtils.remove_entry(@target_domain_dir)
  end

  before { reset_schemas! }

  def reset_schemas!
    ledger = PG.connect(dbname: QA_SWEEP_ERA_BOUNDARY_LEDGER_DATABASE)
    ledger.exec("DROP SCHEMA public CASCADE")
    ledger.exec("CREATE SCHEMA public")
    ledger.close
    QaLedgerRole.own_public!(QA_SWEEP_ERA_BOUNDARY_LEDGER_DATABASE)

    target = PG.connect(dbname: QA_SWEEP_ERA_BOUNDARY_TARGET_DATABASE)
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

  it "runs once per sweep, never per seed, and reports clean on a target with no diverged writes" do
    identify_target!("era-boundary", @target_domain_relpath)

    stdout, stderr, status = run_qa_sweep("era-boundary", "--modes", "era_boundary")

    expect(status.exitstatus).to eq(0), "expected a clean sweep, got:\nSTDOUT:\n#{stdout}\nSTDERR:\n#{stderr}"
    expect(stdout).to include("resolved modes: era_boundary (capabilities=postgres_era,sqlite,translations)")
    # SEEDLESS — no "seed N: held" line at all, unlike every other mode.
    expect(stdout).not_to match(/seed \d+:/)
    expect(stdout).to include("era boundary: no ancestor era holds an unmerged write")
    expect(stdout).to include("clean — era-boundary concluded and released.")

    Hecks.boot(@fixture_dir)
    sweep = QualityControl::Sweep.all.first
    expect(sweep).not_to be_nil
    subjects = sweep.checks.map { |c| c[:subject][:value] }
    expect(subjects).to include(a_string_starting_with("[era_boundary]"))
  end

  # THE DIAL'S OWN DEFAULT — `QualityControlDials::MODES[:era_boundary]`
  # is `false`; an ordinary sweep, with no `--modes` override, must still
  # run exactly the checks it always did.
  it "stays off an ordinary sweep — the real ledger's own dial defaults it off" do
    identify_target!("era-boundary-default", @target_domain_relpath)

    stdout, _stderr, status = run_qa_sweep("era-boundary-default", "--seeds", "1")

    expect(status.exitstatus).to eq(0)
    expect(stdout).not_to include("era_boundary")
  end
end
