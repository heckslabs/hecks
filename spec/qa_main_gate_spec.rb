require "hecks"
require "hecks/ports/persistence/plugins/era"
require "open3"
require "tmpdir"
require_relative "support/qa_ledger_fixture"
require "hecks/quality_control/cli/qa_main_gate"
require "hecks/quality_control/cli/qa_fix_main_bug"

# `hecks quality_control main_check.check_main` and `bug.fix_and_land`, run in-process against a
# disposable PostgresRevision ledger (spec/support/qa_ledger_fixture.rb) and a throwaway git
# repository
# with an origin. The gate, the fixer, the landing and the push are doubles: a spec must not run the
# real gate, land on or push a real main.
RSpec.describe "hecks quality_control check_main and bug.fix_and_land", :io do
  CLI_MAIN = Hecks::QualityControlCli

  # Answers the quick gate's rounds in order; the last round repeats.
  class MainGateStub
    def initialize(*rounds)
      @rounds = rounds
    end

    def run(_dir)
      @rounds.size > 1 ? @rounds.shift : @rounds.first
    end
  end

  # Records what the command would have landed or pushed, and whether the fixer changed the tree.
  class MainShellStub
    attr_reader :calls

    def initialize(fixes: true, landed: true, pushed: true)
      @fixes = fixes
      @landed = landed
      @pushed = pushed
      @calls = []
    end

    def rubocop(dir, files)
      File.write(File.join(dir, "fixed.rb"), "# fixed\n") if @fixes
      @calls << [:rubocop, files]
      ["", true]
    end

    def land(_root, branch)
      @calls << [:land, branch]
      ["", @landed]
    end

    def push(_root)
      @calls << [:push]
      ["", @pushed]
    end
  end

  before(:all) do
    skip "no reachable Postgres — start one to run this spec" unless PostgresProbe.available?

    @ledger = QaLedgerFixture::Ledger.new(database: "hecks_qa_main_gate_spec_#{Process.pid}").stand_up!
    @sandbox = Dir.mktmpdir("qa_main_gate_spec")
    @repo = File.join(@sandbox, "checkout")
    set_git_identity
  end

  after(:all) do
    @ledger&.tear_down!
    FileUtils.remove_entry(@sandbox) if @sandbox
  end

  before do
    @ledger.reset!
    make_repository
    @shell = MainShellStub.new
  end

  def set_git_identity
    { "GIT_AUTHOR_NAME" => "QA", "GIT_AUTHOR_EMAIL" => "qa@example.com",
      "GIT_COMMITTER_NAME" => "QA", "GIT_COMMITTER_EMAIL" => "qa@example.com" }.each { |key, value| ENV[key] = value }
  end

  def git(*argv)
    output, status = Open3.capture2e("git", "-C", @repo, *argv)
    raise output unless status.success?

    output.strip
  end

  # A checkout whose local main is pushed to a bare origin, so the fetch has a remote to read.
  def make_repository
    FileUtils.rm_rf(@repo)
    FileUtils.rm_rf(File.join(@sandbox, "origin.git"))
    Open3.capture2e("git", "init", "-q", "-b", "main", @repo)
    commit_main!("lib/a.rb")
    Open3.capture2e("git", "init", "-q", "--bare", File.join(@sandbox, "origin.git"))
    git("remote", "add", "origin", File.join(@sandbox, "origin.git"))
    git("push", "-q", "origin", "main")
  end

  def commit_main!(path)
    FileUtils.mkdir_p(File.dirname(File.join(@repo, path)))
    File.write(File.join(@repo, path), "# #{path} #{Time.now.to_f}\n")
    git("add", "-A")
    git("commit", "-q", "-m", "change #{path}")
  end

  def result(id, passed:, output: "")
    CLI_MAIN::QaMainGate::GateRun::Result.new(id, "#{id} check", output, passed)
  end

  def green
    [result("rubocop", passed: true), result("shape_ledger", passed: true)]
  end

  def red_rubocop(output = "lib/a.rb:1:1: C: Style/Foo: bad\n")
    [result("rubocop", passed: false, output: output), result("shape_ledger", passed: true)]
  end

  def check_main(gate)
    CLI_MAIN::QaMainGate.call([], root: @repo, env: @ledger.env, gate: gate, shell: @shell)
  end

  def fix_and_land(reference, gate)
    CLI_MAIN::QaFixMainBug.call(["--bug", reference], root: @repo, env: @ledger.env, gate: gate, shell: @shell)
  end

  def bugs
    @ledger.boot.query("QualityControl::Bug.All")
  end

  def checks_recorded
    @ledger.boot.query("QualityControl::MainCheck.All").map { |row| row[:verdict][:value] }
  end

  it "a green main logs no bug and records the verdict", :aggregate_failures do
    expect(check_main(MainGateStub.new(green))).to eq(0)
    expect([bugs.size, checks_recorded]).to eq([0, ["green"]])
  end

  it "a red check logs exactly one bug, proven by its own output", :aggregate_failures do
    expect(check_main(MainGateStub.new(red_rubocop))).to eq(2)
    expect(bugs.map { |row| row[:demonstration][:value] }).to eq(["lib/a.rb:1:1: C: Style/Foo: bad"])
  end

  it "a red check already open is not logged again on the next commit", :aggregate_failures do
    check_main(MainGateStub.new(red_rubocop))
    commit_main!("lib/b.rb")
    check_main(MainGateStub.new(red_rubocop))
    expect(bugs.size).to eq(1)
  end

  it "a bigger bug stops before any fix is made", :aggregate_failures do
    check_main(MainGateStub.new([result("shape_ledger", passed: false, output: "edge missing")]))
    expect(fix_and_land(bugs.first[:reference][:value], MainGateStub.new(green))).to eq(1)
    expect([bugs.first[:status], @shell.calls]).to eq(["logged", []])
  end

  it "a self-contained fix does not land when its gate is still red", :aggregate_failures do
    gate = MainGateStub.new(red_rubocop, red_rubocop)
    expect(check_main(gate)).to eq(2)
    expect(@shell.calls.map(&:first)).to eq([:rubocop])
  end

  it "a self-contained fix lands and pushes once the gate is green on the commit", :aggregate_failures do
    expect(check_main(MainGateStub.new(red_rubocop, green))).to eq(2)
    expect(@shell.calls.map(&:first)).to eq([:rubocop, :land, :push])
  end
end
