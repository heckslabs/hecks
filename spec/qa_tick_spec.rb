require "hecks"
require "hecks/ports/persistence/plugins/era"
require_relative "support/qa_ledger_fixture"
require "pathname"
require "tmpdir"

# `bin/qa_tick`, PROVEN AGAINST THE REAL THING — a real subprocess that
# runs the REAL `bin/qa_pr_check` and the REAL `bin/qa_sweep --all` as
# its own subprocesses, against a disposable PostgresEra ledger
# (`spec/support/qa_ledger_fixture.rb`) and a throwaway git repository
# with its own bare `origin`. The claims: a dirty tree is refused before
# anything runs; the PR check ALWAYS runs before the sweep (stdout is the
# proof — the order of the two banners); the two exit codes fold into one
# with `--all`'s own precedence; and a stale-hold reclaim is counted out
# loud so a recurring one is visible across ticks.
RSpec.describe "bin/qa_tick", :io do
  # THE SAME TRIVIALLY WELL-BEHAVED TARGET `spec/qa_sweep_all_spec.rb`
  # sweeps — read that file's `FIXTURE_TARGET_BLUEBOOK` comment for why a
  # real corpus domain would make a "clean" example flaky.
  TICK_TARGET_BLUEBOOK = <<~RUBY.freeze
    Hecks.bluebook "QaTickFixtureTarget" do
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

  TICK_TARGET_HECKSAGON = <<~RUBY.freeze
    Hecks.hecksagon "QaTickFixtureTarget" do
      QaTickFixtureTarget::Widget.persisted_by("Heki")
    end
  RUBY

  before(:all) do
    skip "no reachable Postgres — start one to run this spec" unless PostgresProbe.available?

    @ledger = QaLedgerFixture::Ledger.new(database: "hecks_qa_tick_spec").stand_up!
    @target_domain_dir = Dir.mktmpdir("qa_tick_spec_target-", InMemoryDomain::ROOT)
    File.write(File.join(@target_domain_dir, "fixture.bluebook"), TICK_TARGET_BLUEBOOK)
    File.write(File.join(@target_domain_dir, "fixture.hecksagon"), TICK_TARGET_HECKSAGON)
    @target_domain_relpath = Pathname.new(@target_domain_dir).relative_path_from(Pathname.new(InMemoryDomain::ROOT)).to_s
  end

  after(:all) do
    @ledger&.tear_down!
    FileUtils.remove_entry(@target_domain_dir) if @target_domain_dir
  end

  before do
    @ledger.reset!
    @origin = Dir.mktmpdir("qa_tick_origin")
    @repo   = Dir.mktmpdir("qa_tick_repo")
    system("git", "init", "-q", "--bare", "-b", "main", @origin, out: File::NULL) or raise "bare init failed"
    git("init", "-q", "-b", "main")
    File.write(File.join(@repo, "README"), "one\n")
    git("add", ".")
    git("commit", "-qm", "init")
    git("remote", "add", "origin", @origin)
    git("push", "-q", "origin", "main")
  end

  after do
    FileUtils.remove_entry(@repo) if @repo
    FileUtils.remove_entry(@origin) if @origin
  end

  def git(*args)
    system("git", "-c", "user.name=spec", "-c", "user.email=spec@example.com", *args, chdir: @repo,
           out: File::NULL, err: File::NULL) or raise "git #{args.join(' ')} failed"
  end

  def tick
    @ledger.run("qa_tick", env: { "QA_REPO_DIR" => @repo })
  end

  def identify!(targets)
    @ledger.boot
    targets.each do |reference, path|
      QualityControl::Target.identify!(reference: { value: reference }, path: { value: path })
    end
  end

  it "refuses a dirty tree before running anything" do
    File.write(File.join(@repo, "scratch.txt"), "uncommitted\n")

    stdout, stderr, status = tick

    expect(status.exitstatus).to eq(1)
    expect(stderr).to include("refused: the working tree is dirty", "scratch.txt")
    expect(stdout).not_to include("── bin/qa_pr_check", "── bin/qa_sweep --all")
  end

  it "rebases, runs the PR check FIRST and the sweep second, and is clean on an empty ledger" do
    stdout, stderr, status = tick

    expect(status.exitstatus).to eq(0), "#{stdout}\n#{stderr}"
    pr_check_at = stdout.index("── bin/qa_pr_check")
    sweep_at    = stdout.index("── bin/qa_sweep --all")
    expect(pr_check_at).not_to be_nil
    expect(sweep_at).not_to be_nil
    expect(pr_check_at).to be < sweep_at
    expect(stdout).to include("── git fetch origin && git rebase origin/main",
                              "no PRs tracked as open", "rotation is empty",
                              "stale holds reclaimed: 0", "tick: clean (exit 0)")
  end

  it "reports an operational error from the sweep as the tick's own exit 1" do
    identify!("broken_one" => "qa/stress_domains/__qa_tick_spec_does_not_exist__")

    stdout, _stderr, status = tick

    expect(status.exitstatus).to eq(1)
    expect(stdout).to include("bin/qa_pr_check:   clean (exit 0)",
                              "bin/qa_sweep --all: operational error (exit 1)",
                              "tick: operational error (exit 1)")
  end

  it "counts a stale hold the sweep reclaimed, so a recurring one is visible across ticks" do
    identify!("stale_one" => @target_domain_relpath)
    QualityControl::Target.find("stale_one").claim!(held_by: { value: "ghost" }, now: { value: Time.now.to_i - 5_000 })

    stdout, stderr, status = tick

    expect(status.exitstatus).to eq(0), "#{stdout}\n#{stderr}"
    expect(stdout).to include("reclaimed stale hold: stale_one (held by ghost,", "stale holds reclaimed: 1 (stale_one)",
                              "tick: clean (exit 0)")
  end
end
