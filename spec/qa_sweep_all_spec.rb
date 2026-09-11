require "hecks"
require "hecks/ports/persistence/plugins/era"
require_relative "support/postgres_probe"
require_relative "support/qa_ledger_role"
require "open3"
require "tempfile"
require "fileutils"
require "pathname"

# `bin/qa_sweep --all`, PROVEN AGAINST THE REAL THING — not a stand-in
# for it. Every property this file exists to prove (genuine parallelism,
# a claim that actually holds across processes, output that never
# interleaves, exit-code precedence) is a fact about REAL `Process.spawn`
# children hitting a REAL `PostgresEra`-backed ledger — `bin/qa_sweep`'s
# own top-of-file comment explains exactly why none of it can be proven
# by mocking `Target.claim!` or `bin/qa_sweep` itself.
#
# WHY A DISPOSABLE LEDGER, NOT THE REAL `hecks_quality_control` ONE —
# `spec/quality_control_spec.rb`'s own header already says it: "a spec
# that wrote to the real ledger would leave it different after every
# run, which is the one thing a durable store must not do to its own
# test." That spec dodges the problem by booting the SAME chapter bound
# to Memory instead of Postgres — not an option here, because Memory is
# confirmed process-local (`lib/hecks/runtime/aggregate_lock.rb`'s own
# header) and this file's entire point is to prove something true only
# across REAL separate OS processes. So this spec stands up its OWN
# throwaway Postgres database and a fixture domain directory that loads
# the REAL `qa/bluebook/quality_control.bluebook` (symlinked, never
# copied, so it can never quietly drift from what `bin/qa_sweep` actually
# dispatches against) under a fixture `.hecksagon`/`.world` pointing at
# that database instead — the same "swap only the WIRING, never the
# chapter" move `spec/quality_control_spec.rb` already makes for Memory,
# aimed at `PostgresEra` instead.
#
# `QA_SWEEP_DOMAIN_DIR` (bin/qa_sweep's own header, and its own comment
# by that constant) is the one-line seam that makes this reachable at
# all: every subprocess this file spawns — `bin/qa_sweep --all` itself,
# and every ORDINARY `bin/qa_sweep <target>` it goes on to spawn as ITS
# OWN children — inherits it from `Open3.capture3`'s own env hash the
# same way any child inherits its parent's environment, so one setting
# reaches the whole tree with no code path in `bin/qa_sweep` needing to
# know a spec is driving it.
RSpec.describe "bin/qa_sweep --all", :io do
  QA_SWEEP_ALL_DATABASE = "hecks_qa_sweep_all_spec".freeze

  # THE "FOUND SOMETHING" EXAMPLE'S OWN FIXTURE CRATE — a small
  # STANDALONE Rust crate (own `Cargo.toml`, `spec/fixtures/qa_sweep_all_
  # found_fixture_rust/`, deliberately outside `rust/`'s own workspace/
  # feature list) whose compiled binary always answers a fixed,
  # hand-written mismatch against `spec/fixtures/qa_sweep_all_found_
  # fixture`'s own trivially well-behaved Ruby domain — see both
  # fixtures' own header comments, and `run_qa_sweep`'s own comment on
  # `QA_SWEEP_RUST_DIR` below, for the full reasoning.
  FIXTURE_RUST_DIR = File.join(InMemoryDomain::ROOT, "spec/fixtures/qa_sweep_all_found_fixture_rust").freeze

  # THE FIXTURE LEDGER'S OWN `.hecksagon` — line-for-line what
  # `qa/bluebook/quality_control.hecksagon` declares (every aggregate
  # `persisted_by("PostgresEra")`, the same two dormant/bound ports),
  # EXCEPT it binds no adapter for the `CI` port at all. The real file's
  # own comment explains that port is bound by `Folder#load_project`
  # discovering a sibling `qa/adapters/` directory purely by its
  # PRESENCE next to the real `qa/bluebook` — a relationship this
  # fixture directory, living under `Dir.mktmpdir`, does not share and
  # has no reason to reproduce: `bin/qa_sweep` (single-target or `--all`)
  # never dispatches `Clearance.CI.Run` at all, so an unbound `CI` port
  # here is exactly as dormant, and exactly as harmless, as the real
  # file's own deliberately-unbound `IssueTracker`.
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

  # ONE STANDALONE SCRIPT, RUN AS TWO REAL CONCURRENT PROCESSES — this is
  # the mechanism `--all`'s own "no extra lock needed" claim rests on
  # (`bin/qa_sweep`'s own top-of-file comment), exercised DIRECTLY rather
  # than through a full sweep: two racers dispatch the exact same
  # `QualityControl::Target.claim!` bin/qa_sweep itself dispatches, both
  # against the SAME target reference, and whichever loses prints
  # "refused" and exits 1 — a real `Hecks::Runtime::GivenNotMet`, not a
  # simulated one.
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
  # violate. Earlier drafts of this spec pointed "clean" examples at
  # `qa/stress_domains/ledger_ordering`, a REAL stress domain already in
  # this repository — and that was the wrong call, caught live: this
  # repository's own QA practice is ACTIVELY hunting bugs in that domain
  # (and its Rust conformance binary is rebuilt fresh, unmemoized, by
  # EVERY separate `bin/qa_sweep` process — this file's own `RustConformance
  # Helpers` note explains why), so a domain that swept clean once here
  # surprised on a later run, from ordinary, unrelated churn in a
  # worktree several concurrent sessions share — not a bug in `--all`,
  # but exactly the kind of flakiness a "clean" fixture must never carry.
  # This one has no Rust feature (`rust/Cargo.toml` never names it), so
  # `bin/qa_sweep` always runs it in `ruby_only` mode — no compiled
  # binary, no build step, nothing else's work can ever move it.
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
  # `--all`'s own second wave. No `.world` is needed: `IsolatedBoot#
  # rebind_to_postgres_era!` writes its own per-boot `.world` pointing at
  # the throwaway database/schema `bin/qa_sweep` itself owns.
  FIXTURE_PG_TARGET_HECKSAGON = <<~RUBY.freeze
    Hecks.hecksagon "QaSweepAllFixtureTarget" do
      QaSweepAllFixtureTarget::Widget.persisted_by("PostgresEra")
    end
  RUBY

  before(:all) do
    skip "no reachable Postgres — start one to run this spec" unless PostgresProbe.available?

    @fixture_root = Dir.mktmpdir("qa_sweep_all_spec")
    @fixture_dir  = File.join(@fixture_root, "bluebook")
    FileUtils.mkdir_p(@fixture_dir)
    FileUtils.ln_s(File.join(InMemoryDomain::ROOT, "qa/bluebook/quality_control.bluebook"),
                   File.join(@fixture_dir, "quality_control.bluebook"))
    File.write(File.join(@fixture_dir, "quality_control.hecksagon"), FIXTURE_HECKSAGON)
    # THE SAME URL SHAPE THE REAL LEDGER BINDS (qa/bluebook/quality_control
    # .world): the database by URL, as `hecks_qa`, an ordinary owner role
    # — PostgresEra refuses to boot as the ambient superuser (BUG#24).
    # `bin/qa_postgres_role`, run for real below, is what makes it
    # connectable — the one operator step that file's header names.
    File.write(File.join(@fixture_dir, "quality_control.world"), <<~RUBY)
      Hecks.world "QualityControl" do
        realm "QA"
        persisted_by("PostgresEra") { database "#{QaLedgerRole.url(QA_SWEEP_ALL_DATABASE)}" }
      end
    RUBY

    # LIVING INSIDE THE REAL REPO ROOT, NOT `/tmp` — `bin/qa_sweep`
    # always resolves a `Target`'s own `path` as `File.join(ROOT,
    # target_path)` against the REAL repository root (`bin/qa_sweep`'s
    # own `ROOT` constant is fixed to where the script itself lives,
    # independent of `QA_SWEEP_DOMAIN_DIR`) — a `Target.path` outside
    # that tree, however this spec labels it, would never resolve.
    # Removed again in `after(:all)`, the same as `@fixture_root`.
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
    admin.exec("DROP DATABASE IF EXISTS #{QA_SWEEP_ALL_DATABASE} WITH (FORCE)")
    admin.exec("CREATE DATABASE #{QA_SWEEP_ALL_DATABASE}")
    admin.close
    @role_report = QaLedgerRole.provision!(QA_SWEEP_ALL_DATABASE)
  end

  after(:all) do
    next unless PostgresProbe.available?

    admin = PG.connect(dbname: "postgres")
    admin.exec("DROP DATABASE IF EXISTS #{QA_SWEEP_ALL_DATABASE} WITH (FORCE)")
    admin.close
    FileUtils.remove_entry(@fixture_root)
    FileUtils.remove_entry(@target_domain_dir)
    FileUtils.remove_entry(@pg_target_domain_dir)
  end

  # A FRESH SCHEMA BEFORE EVERY EXAMPLE (`postgres_era_concurrent_
  # dispatch_spec.rb`'s own convention) — a Sweep, Bug or Target row a
  # PRIOR example claimed/concluded/left held must never leak into the
  # next one's own rotation.
  before { reset_schema! }

  def reset_schema!
    scrub = PG.connect(dbname: QA_SWEEP_ALL_DATABASE)
    scrub.exec("DROP SCHEMA public CASCADE")
    scrub.exec("CREATE SCHEMA public")
    scrub.close
    QaLedgerRole.own_public!(QA_SWEEP_ALL_DATABASE)
  end

  # THE OPERATOR STEP, PROVEN ON A DISPOSABLE DATABASE (BUG#24) — the
  # exact `bin/qa_postgres_role <database>` the real ledger's `.world`
  # header asks an operator to run once against `hecks_quality_control`,
  # already run for real in `before(:all)` above against this spec's own
  # throwaway database. What it reports, what a second run reports
  # (idempotent: nothing left to do), and that the resulting owner is
  # genuinely an ORDINARY role — the whole point — are the three facts an
  # operator is being asked to trust.
  it "bin/qa_postgres_role hands the ledger's database to hecks_qa, an ordinary owner, idempotently" do
    expect(@role_report).to include("#{QA_SWEEP_ALL_DATABASE} is hecks_qa's")
    expect(@role_report).to include("database #{QA_SWEEP_ALL_DATABASE}: owner")

    again = QaLedgerRole.provision!(QA_SWEEP_ALL_DATABASE)
    expect(again).to include("already: role hecks_qa exists, ordinary")
    expect(again).to include("already: database #{QA_SWEEP_ALL_DATABASE} already owned by hecks_qa")
    expect(again).not_to include("did:")

    db = PG.connect(dbname: QA_SWEEP_ALL_DATABASE)
    role = db.exec("SELECT rolsuper, rolbypassrls FROM pg_roles WHERE rolname = 'hecks_qa'")[0]
    owner = db.exec("SELECT pg_get_userbyid(datdba) AS owner FROM pg_database WHERE datname = current_database()")[0]
    db.close
    expect(role).to eq("rolsuper" => "f", "rolbypassrls" => "f")
    expect(owner["owner"]).to eq("hecks_qa")

    # ...and a boot over that URL is the ordinary, fenced kind: it neither
    # refuses nor warns, where the ambient superuser would have refused
    expect { identify_targets!("fenced" => @target_domain_relpath) }.not_to output.to_stderr
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
  # one, and `QA_SWEEP_RUST_DIR` (harmless for every example except the
  # "found something" one — no OTHER target name in this file ever
  # matches a feature `FIXTURE_RUST_DIR`'s own `Cargo.toml` declares) is
  # what tells `found_one`'s own differential diff to build/run this
  # spec's own hand-maintained fixture crate rather than reaching for
  # the real `rust/`.
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

  it "is a clean, explicit no-op when the rotation is completely empty" do
    stdout, _stderr, status = run_qa_sweep("--all")

    expect(status.exitstatus).to eq(0)
    expect(stdout).to include("rotation is empty")
  end

  # THE CENTRAL CLAIM `--all` EXISTS FOR, PROVEN WITHOUT TRUSTING THE
  # CLOCK. An earlier version of this spec compared a single-target
  # baseline's own wall-clock duration against a two-target `--all`
  # run's — and was genuinely flaky, caught live: this repository's own
  # dev/CI machines run several concurrent agents at once (this session's
  # own `uptime` read a load average of 9.7 on 12 cores, from OTHER
  # sessions' own work, while writing this spec), so two measurements
  # taken moments apart can each be skewed by however busy the machine
  # happens to be at THAT instant, in either direction — a real
  # `--all` run once measured slower than `2 * baseline` despite
  # spawning genuinely concurrently, simply because the baseline
  # measurement happened to land in a quieter moment.
  #
  # PID LIVENESS DOES NOT HAVE THAT PROBLEM. Two real `bin/qa_sweep
  # <target>` children — the exact same spawn shape `spawn_sweep_child`
  # uses per target inside `--all` itself — are spawned back to back
  # (`Process.spawn` returns immediately either way), then checked for
  # life together immediately after. A SERIALIZED implementation
  # (spawn one, block on `Process.waitpid2`, spawn the next) could NEVER
  # have a second `bin/qa_sweep` process alive before the first one
  # exits, no matter how fast or slow the machine is at that moment —
  # heavier system load only makes each child take LONGER, which makes
  # this check MORE reliable, never less.
  it "runs two real bin/qa_sweep children as genuinely concurrent OS processes — both alive at once" do
    identify_targets!(
      "clone_one" => @target_domain_relpath,
      "clone_two" => @target_domain_relpath
    )

    children = %w[clone_one clone_two].map do |target_reference|
      log = Tempfile.new(target_reference)
      pid = Process.spawn(
        { "QA_SWEEP_DOMAIN_DIR" => @fixture_dir },
        "bundle", "exec", "ruby", File.join(InMemoryDomain::ROOT, "bin/qa_sweep"), target_reference, "--seeds", "3",
        out: log, err: log, chdir: InMemoryDomain::ROOT
      )
      { pid: pid, log: log }
    end

    both_alive_at_once = children.all? { |c| process_alive?(c[:pid]) }

    exit_statuses = children.map do |c|
      _pid, status = Process.waitpid2(c[:pid])
      c[:log].close
      status.exitstatus
    end

    expect(both_alive_at_once).to be true
    expect(exit_statuses).to all(eq(0))
  end

  it "lets exactly one of two real concurrent claims on the SAME target win" do
    identify_targets!("contested" => @target_domain_relpath)
    script = File.join(@fixture_root, "claim_race.rb")
    File.write(script, CLAIM_RACE_SCRIPT)

    racers = %w[racer_a racer_b].map do |engineer|
      log = Tempfile.new(engineer)
      pid = Process.spawn("bundle", "exec", "ruby", script, InMemoryDomain::ROOT, @fixture_dir, "contested", engineer,
                          out: log, err: log, chdir: InMemoryDomain::ROOT)
      { pid: pid, log: log }
    end

    outcomes = racers.map do |racer|
      _pid, status = Process.waitpid2(racer[:pid])
      racer[:log].rewind
      output = racer[:log].read.strip
      racer[:log].close
      { exitstatus: status.exitstatus, output: output }
    end

    expect(outcomes.map { |o| o[:exitstatus] }.sort).to eq([0, 1])
    expect(outcomes.map { |o| o[:output] }).to contain_exactly("claimed", "refused")
  end

  # A GENUINE FINDING, AN OPERATIONAL ERROR, AND A CLEAN TARGET, ALL AT
  # ONCE — three children writing to three SEPARATE temp files the whole
  # time (bin/qa_sweep's own `spawn_sweep_child`), so nothing here is
  # racing anything else's stdout.
  #
  # `found_one` USED TO POINT AT `qa/stress_domains/waybill` — a REAL,
  # then-currently-open divergence in this repository's own live QA
  # rotation (confirmed live while building the spec this replaced: Ruby
  # shipped a Consignment, Rust cancelled it — a real `Manifest::Slot.
  # Fill` routing gap). That made this example FRAGILE BY DESIGN: it
  # depended on some domain in the shared rotation staying broken forever
  # to keep passing, which is backwards — the whole point of this
  # practice is to drive every domain in the rotation to zero known
  # divergences, and this example broke for real the moment BUG#10's fix
  # (PR #551) closed that exact gap.
  #
  # `found_one` now points at `spec/fixtures/qa_sweep_all_found_fixture`
  # instead — a trivially well-behaved Ruby domain (this spec's own,
  # same spirit as `FIXTURE_TARGET_BLUEBOOK` above) diffed against
  # `spec/fixtures/qa_sweep_all_found_fixture_rust`, a small STANDALONE
  # Rust crate (own `Cargo.toml`, outside `rust/`'s own workspace/feature
  # list entirely) whose compiled binary always answers a fixed,
  # hand-written JSON naming a sentinel id
  # (`__qa_sweep_all_spec_phantom__`) the Ruby side can never generate.
  # `QA_SWEEP_RUST_DIR` (bin/qa_sweep's own header, mirroring the
  # pre-existing `QA_SWEEP_DOMAIN_DIR`) is what points THIS spec's own
  # real subprocess at that fixture crate instead of the real `rust/`
  # one. The divergence is total and permanent by construction — it
  # never depends on what the fuzzer happened to generate, and never
  # depends on anything ELSE in this codebase, healthy or not.
  it "captures each child's own output without interleaving, and a real finding outranks a real error" do
    identify_targets!(
      "clean_one"  => @target_domain_relpath,
      "found_one"  => "spec/fixtures/qa_sweep_all_found_fixture",
      "broken_one" => "qa/stress_domains/__qa_sweep_all_spec_does_not_exist__"
    )

    stdout, _stderr, status = run_qa_sweep("--all", "--seeds", "2")

    expect(status.exitstatus).to eq(2)
    expect(stdout).to include("clean (1): clean_one", "OPERATIONAL ERRORS (1)",
                              "-- broken_one (exit 1) --", "FOUND SOMETHING (1)")

    # THE UN-INTERLEAVED, UN-ABRIDGED PROOF — `found_one`'s own report is
    # the LAST section this script ever prints (see `print_all_mode_
    # report`), so everything from its own header to the end of output
    # came from ONE child's own temp file, never touched by
    # `clean_one`/`broken_one`'s own concurrent writes. If output ever
    # interleaved, either target's own name would show up inside a
    # report that has nothing to do with it.
    found_report = stdout[/^#{'#' * 72}\n# found_one\n.*\z/m]
    expect(found_report).not_to be_nil
    expect(found_report).to include("target:      found_one", "sweep:       SW-found_one-",
                                    "-- instances --", "-- events --")
    expect(found_report).not_to include("clean_one", "broken_one")
  end

  # MODES ARE DATA — `bin/qa_sweep` prints the one rule's answer
  # (`enabled ∩ eligible`, `Hecks::Fuzzing::TargetCapabilities`) on its
  # own `resolved modes:` line, and `--modes` overrides the enabled set
  # for one run. The fixture target binds Heki and has no Cargo feature,
  # so its capabilities are exactly `sqlite` — the ruby_only seat, with
  # self-consistency folded in, and nothing else.
  it "prints the resolved modes and capabilities, and honours --modes as the enabled set" do
    identify_targets!("modes_one" => @target_domain_relpath)

    stdout, _stderr, status = run_qa_sweep("modes_one", "--seeds", "2")
    expect(status.exitstatus).to eq(0)
    expect(stdout).to include("resolved modes: ruby_only,self_consistency (capabilities=sqlite)")
    expect(stdout).to include("seed 1: held (ruby_only, self_consistency)")

    stdout, _stderr, status = run_qa_sweep("modes_one", "--seeds", "2", "--modes", "ruby_only")
    expect(status.exitstatus).to eq(0)
    expect(stdout).to include("resolved modes: ruby_only (capabilities=sqlite)")
    expect(stdout).to include("seed 1: held (ruby_only)")
  end

  it "refuses, before claiming anything, a --modes set this target cannot resolve a comparison seat from" do
    identify_targets!("modes_none" => @target_domain_relpath)

    stdout, stderr, status = run_qa_sweep("modes_none", "--modes", "differential")
    expect(status.exitstatus).to eq(1)
    expect(stderr + stdout).to include("resolves no comparison mode at all")

    _stdout, stderr, status = run_qa_sweep("modes_none", "--modes", "telepathy")
    expect(status.exitstatus).to eq(1)
    expect(stderr).to include("no such mode: telepathy")

    # Nothing was claimed or opened — the refusal came before the claim.
    Hecks.boot(@fixture_dir)
    expect(QualityControl::Target.find("modes_none").status.value).to eq("waiting")
  end

  # THE SECOND WAVE — `--all` used to abort on `--persistence-parity`;
  # now it runs the parity pass ITSELF over every target that came back
  # clean from wave 1 AND binds PostgresEra. `pg_one` does; `heki_one`
  # does not, so exactly one wave-2 child runs, as an ordinary
  # `bin/qa_sweep pg_one --persistence-parity`, and its own row joins the
  # report under a `[parity wave]` label. `--no-parity` skips it.
  it "runs persistence parity as a second wave over PostgresEra-bound targets that came back clean" do
    identify_targets!("heki_one" => @target_domain_relpath, "pg_one" => @pg_target_domain_relpath)

    stdout, _stderr, status = run_qa_sweep("--all", "--seeds", "2")

    expect(status.exitstatus).to eq(0)
    expect(stdout).to include("parity wave: Memory vs real PostgresEra for 1 target(s): pg_one")
    expect(stdout).to include("clean (3): heki_one, pg_one, pg_one [parity wave]")
    expect(stdout)
      .to match(/^  pg_one: ruby_only,self_consistency \(capabilities: postgres_era,sqlite; deferred: persistence_parity\)$/)
    expect(stdout).to match(/^  pg_one \[parity wave\]: persistence_parity \(capabilities: postgres_era,sqlite\)$/)
    expect(stdout).to match(/^  heki_one: ruby_only,self_consistency \(capabilities: sqlite\)$/)

    stdout, _stderr, status = run_qa_sweep("--all", "--seeds", "2", "--no-parity")
    expect(status.exitstatus).to eq(0)
    expect(stdout).not_to include("parity wave")
    expect(stdout).to include("clean (2): heki_one, pg_one")
  end

  # THE `dry_runs` COMPARISON SURFACE FINDS SOMETHING ON ITS OWN — item 5
  # of the detection plan. `--dry-run 1` turns every generated command
  # step into a `{"dry_run": …}` step, so the Ruby side of
  # `spec/fixtures/qa_sweep_all_dry_run_fixture` produces NO instances,
  # events or refusals — exactly what the fixture crate's
  # `qa_sweep_all_dry_run_fixture` feature answers — and the two sides
  # differ on `dry_runs` alone (the binary names a sentinel verb per
  # dry-run step; see `qa_sweep_all_found_fixture_rust/src/main.rs`).
  # `--self-consistency false` keeps the Rust rehydration door out of
  # it: this example is about ONE surface, proven in isolation.
  it "finds a dry_runs-only divergence, with every other surface agreeing" do
    identify_targets!("dry_run_one" => "spec/fixtures/qa_sweep_all_dry_run_fixture")

    stdout, _stderr, status = run_qa_sweep("dry_run_one", "--seeds", "2", "--dry-run", "1", "--self-consistency", "false")

    expect(status.exitstatus).to eq(2)
    expect(stdout).to include("resolved modes: differential,properties_in_differential,structural_skip_report " \
                              "(capabilities=rust,sqlite)")
    expect(stdout).to include("seed 1: SURPRISED (differential)")
    expect(stdout).to include("subject:     [differential] qa_sweep_all_dry_run_fixture fuzz seed 1")
    expect(stdout).to include("observation: diverged on: dry_runs", "-- dry_runs --")
    expect(stdout).not_to include("-- instances --", "-- events --", "-- refusals --")
    expect(stdout).to include("__qa_sweep_all_spec_phantom_dry_run__")
  end

  it "exits 1 when every child hit an operational error and nothing was ever found" do
    identify_targets!(
      "broken_a" => "qa/stress_domains/__qa_sweep_all_spec_nope_a__",
      "broken_b" => "qa/stress_domains/__qa_sweep_all_spec_nope_b__"
    )

    stdout, _stderr, status = run_qa_sweep("--all")

    expect(status.exitstatus).to eq(1)
    expect(stdout).to include("clean (0): none")
    expect(stdout).to include("OPERATIONAL ERRORS (2)")
    expect(stdout).not_to include("FOUND SOMETHING")
  end
end
