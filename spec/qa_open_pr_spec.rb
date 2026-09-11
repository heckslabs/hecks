require "hecks"
require "hecks/ports/persistence/plugins/era"
require_relative "support/qa_ledger_fixture"
require "json"
require "tmpdir"

# `bin/qa_open_pr`, PROVEN AGAINST THE REAL THING — a real subprocess, a
# real disposable PostgresEra ledger (`spec/support/qa_ledger_fixture.rb`),
# a real throwaway git repository on a `qa/…` branch, and a FAKE `gh` on
# PATH: a small script that records every argv it was called with and
# answers `pr view`/`pr create`/`pr merge` the way the real one does, from
# a state file. GitHub itself is the one thing this spec must never
# touch; everything else the script does is exercised for real.
RSpec.describe "bin/qa_open_pr", :io do
  FAKE_GH = <<~'RUBY'.freeze
    #!/usr/bin/env ruby
    require "json"
    log   = ENV.fetch("FAKE_GH_LOG")
    state = ENV.fetch("FAKE_GH_STATE")
    File.open(log, "a") { |f| f.puts ARGV.map { |arg| arg.gsub("\n", "\\n") }.join(" ") }

    case ARGV[0, 2]
    when %w[pr view]
      exit 1 unless File.exist?(state)
      puts File.read(state)
    when %w[pr create]
      args   = ARGV.dup
      branch = args[args.index("--head") + 1]
      title  = args[args.index("--title") + 1]
      head   = `git rev-parse HEAD`.strip
      number = ENV.fetch("FAKE_GH_NUMBER", "777").to_i
      File.write(state, JSON.generate(number: number, url: "https://github.com/heckslabs/hecks/pull/#{number}",
                                      headRefName: branch, headRefOid: head, title: title, state: "OPEN"))
      puts "https://github.com/heckslabs/hecks/pull/#{number}"
    when %w[pr merge]
      exit 0
    else
      warn "fake gh: unexpected #{ARGV.inspect}"
      exit 2
    end
  RUBY

  before(:all) do
    skip "no reachable Postgres — start one to run this spec" unless PostgresProbe.available?

    @ledger = QaLedgerFixture::Ledger.new(database: "hecks_qa_open_pr_spec").stand_up!
    @shim_dir = Dir.mktmpdir("fake_gh")
    File.write(File.join(@shim_dir, "gh"), FAKE_GH)
    File.chmod(0o755, File.join(@shim_dir, "gh"))
  end

  after(:all) do
    @ledger&.tear_down!
    FileUtils.remove_entry(@shim_dir) if @shim_dir
  end

  before do
    @ledger.reset!
    @repo = Dir.mktmpdir("qa_open_pr_repo")
    git("init", "-q", "-b", "main")
    File.write(File.join(@repo, "README"), "one\n")
    git("add", ".")
    git("commit", "-qm", "init")
    @gh_log   = File.join(@repo, ".fake_gh.log")
    @gh_state = File.join(@repo, ".fake_gh.json")
  end

  after { FileUtils.remove_entry(@repo) if @repo }

  def git(*args)
    system("git", "-c", "user.name=spec", "-c", "user.email=spec@example.com", *args, chdir: @repo,
           out: File::NULL, err: File::NULL) or raise "git #{args.join(' ')} failed"
  end

  def head = `git -C #{@repo} rev-parse HEAD`.strip

  def on_branch(name)
    git("checkout", "-qb", name)
    File.write(File.join(@repo, "fix.rb"), "fixed\n")
    git("add", ".")
    git("commit", "-qm", "the fix")
    # THE LOG/STATE FILES ARE IGNORED, so the tree reads clean.
    File.write(File.join(@repo, ".git/info/exclude"), ".fake_gh.*\n")
  end

  def open_pr(*args)
    env = { "PATH" => "#{@shim_dir}:#{ENV.fetch('PATH')}", "QA_REPO_DIR" => @repo,
            "FAKE_GH_LOG" => @gh_log, "FAKE_GH_STATE" => @gh_state }
    @ledger.run("qa_open_pr", *args, env: env)
  end

  def gh_calls = File.exist?(@gh_log) ? File.readlines(@gh_log, chomp: true) : []

  def a_fixed_bug(commit:)
    @ledger.boot
    target = QualityControl::Target.identify!(reference: { value: "banking" }, path: { value: "examples/banking" })
    sweep  = QualityControl::Sweep.open!(target: target.id, reference: { value: "SW-1" }, engineer: { value: "qa_sweep" })
    bug = QualityControl::Bug.log!(sweep: sweep.id, reference: { value: "BUG#1" }, sequence: { value: 1 },
                                   title: { value: "t" }, demonstration: { value: "d" }, symptom: { value: "s" },
                                   expectation: { value: "e" }, submitter: { value: "x" })
    return bug unless commit

    bug.investigate!(site: { value: "lib/x.rb" }, cause: { value: "c" })
    bug.fix!(reference: { value: "BUG#1" }, commit: { value: commit })
  end

  def patches_on_file
    @ledger.boot.query("QualityControl::Patch.All")
           .map { |row| [row[:number][:value], row[:commit][:value], row[:opened_at][:value]] }
  end

  def improvements_on_file
    @ledger.boot.query("QualityControl::Improvement.All")
           .map { |row| [row[:number][:value], row[:status], row[:commit].to_h[:value], row[:angle]] }
  end

  it "refuses a branch outside BRANCH_PREFIX, before touching gh or the ledger" do
    on_branch("loop-parity/old-habit")
    a_fixed_bug(commit: head)

    _stdout, stderr, status = open_pr("--bug", "BUG#1", "--title", "fix")

    expect(status.exitstatus).to eq(1)
    expect(stderr).to include("does not start with QualityControlDials::BRANCH_PREFIX")
    expect(gh_calls).to be_empty
    expect(patches_on_file).to be_empty
  end

  it "refuses a bug that is not fixed" do
    on_branch("qa/logged-only")
    a_fixed_bug(commit: nil)

    _stdout, stderr, status = open_pr("--bug", "BUG#1", "--title", "fix")

    expect(status.exitstatus).to eq(1)
    expect(stderr).to include('BUG#1 is "logged", not "fixed"')
    expect(gh_calls).to be_empty
  end

  it "refuses a fix commit that is not on HEAD" do
    on_branch("qa/wrong-commit")
    a_fixed_bug(commit: "deadbeef1")

    _stdout, stderr, status = open_pr("--bug", "BUG#1", "--title", "fix")

    expect(status.exitstatus).to eq(1)
    expect(stderr).to include("is not an ancestor of HEAD")
    expect(gh_calls).to be_empty
  end

  it "opens the PR, records it with its head commit and the time, and queues auto-merge" do
    on_branch("qa/bug-1")
    a_fixed_bug(commit: head)
    before = Time.now.to_i

    stdout, stderr, status = open_pr("--bug", "BUG#1", "--title", "BUG#1: refuse the alias")

    expect(status.exitstatus).to eq(0), "#{stdout}\n#{stderr}"
    expect(gh_calls.map { |c| c.split[0, 2].join(" ") }).to eq(["pr view", "pr create", "pr view", "pr merge"])
    expect(gh_calls.grep(/^pr create/).first).to include("--head qa/bug-1", "--title BUG#1: refuse the alias")
    expect(gh_calls.grep(/^pr create/).first).not_to include("--draft")
    expect(gh_calls.grep(/^pr merge/).first).to include("777 --auto --squash")
    expect(stdout).to include("recorded Patch #777 for BUG#1", "auto-merge queued for #777")

    number, commit, opened_at = patches_on_file.first
    expect([number, commit]).to eq([777, head])
    expect(opened_at).to be >= before
  end

  # RUN TWICE: the PR is already open on this branch, the number is
  # already on file — nothing is created or recorded a second time.
  it "is idempotent on a PR already open and a number already recorded" do
    on_branch("qa/bug-1")
    a_fixed_bug(commit: head)
    open_pr("--bug", "BUG#1", "--title", "BUG#1: refuse the alias")

    stdout, _stderr, status = open_pr("--bug", "BUG#1", "--title", "BUG#1: refuse the alias")

    expect(status.exitstatus).to eq(0)
    expect(stdout).to include("already open", "already recorded")
    expect(gh_calls.count { |c| c.start_with?("pr create") }).to eq(1)
    expect(patches_on_file.size).to eq(1)
  end

  it "records deliberate work as an Improvement, landed, citing an investigating angle" do
    on_branch("qa/angle-1")
    @ledger.boot
    angle = QualityControl::Angle.propose!(reference: { value: "ANGLE-1" }, premise: { value: "x" * 60 },
                                           citation: { value: "BUG#1" }, proposer: { value: "x" },
                                           now: { value: 1 })

    _stdout, stderr, status = open_pr("--improvement", "--angle", "ANGLE-1", "--title", "qa: build it")
    expect(status.exitstatus).to eq(1)
    expect(stderr).to include('ANGLE-1 is "proposed", not "investigating"')

    angle.investigate!
    stdout, stderr, status = open_pr("--improvement", "--angle", "ANGLE-1", "--title", "qa: build it")

    expect(status.exitstatus).to eq(0), "#{stdout}\n#{stderr}"
    expect(improvements_on_file).to eq([[777, "landed", head, "ANGLE-1"]])
  end

  # THE CAP — `PR_CAP_PER_DAY` is 0 (uncapped) in the real bluebook, and
  # the fixture symlinks the real bluebook. So this one example boots a
  # DERIVED copy with the dial set to 1 — derived at run time from the
  # real file, substituting one line, so it cannot quietly drift from it
  # either — and proves the count is read from `OpenedSince`.
  it "refuses one more PR than PR_CAP_PER_DAY allows for today" do
    on_branch("qa/capped")
    a_fixed_bug(commit: head)
    @ledger.boot
    QualityControl::Improvement.open!(number: { value: 1 }, url: { value: "u" }, branch: { value: "qa/earlier" },
                                      title: { value: "earlier today" }, now: { value: Time.now.to_i })

    capped_dir = File.join(Dir.mktmpdir("qa_open_pr_capped"), "bluebook")
    FileUtils.mkdir_p(capped_dir)
    real = File.read(File.join(InMemoryDomain::ROOT, "qa/bluebook/quality_control.bluebook"))
    expect(real).to include("PR_CAP_PER_DAY = 0")
    File.write(File.join(capped_dir, "quality_control.bluebook"), real.sub("PR_CAP_PER_DAY = 0", "PR_CAP_PER_DAY = 1"))
    FileUtils.cp(File.join(@ledger.dir, "quality_control.hecksagon"), capped_dir)
    FileUtils.cp(File.join(@ledger.dir, "quality_control.world"), capped_dir)

    env = { "PATH" => "#{@shim_dir}:#{ENV.fetch('PATH')}", "QA_REPO_DIR" => @repo,
            "FAKE_GH_LOG" => @gh_log, "FAKE_GH_STATE" => @gh_state, "QA_SWEEP_DOMAIN_DIR" => capped_dir }
    _stdout, stderr, status = @ledger.run("qa_open_pr", "--bug", "BUG#1", "--title", "one too many", env: env)

    expect(status.exitstatus).to eq(1)
    expect(stderr).to include("1 PR(s) already opened since local midnight", "PR_CAP_PER_DAY is 1")
    expect(gh_calls).to be_empty
    expect(patches_on_file).to be_empty
  end
end
