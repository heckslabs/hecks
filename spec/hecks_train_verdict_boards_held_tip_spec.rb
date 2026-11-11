require "spec_helper"
require "fileutils"
require "json"
require "open3"
require "securerandom"
require "tmpdir"

# A verified tip waits behind the open train pull request ahead of it. When that pull request merges
# (CI done) or closes, the next observation of it boards the tip with no `Integration.advance!` and
# no new landing; while another pull request stays open, nothing boards. The domain is in Memory;
# the repository is a throwaway one with a bare remote, and GitHub and the push train are fakes.
RSpec.describe "a verdict on the train pull request ahead boards the tip held behind it" do
  let(:dir) { File.realpath(Dir.mktmpdir("hecks-held-tip")) }
  let(:repo) { File.join(dir, "main") }
  let(:stages) { instance_double(Hecks::Adapters::GitRehearsal::Stages, run: []) }
  let(:saga) { "MainIntegration" }

  before(:all) { @hecks = boot_hecks_in_memory }

  before do
    open_repository
    allow(Hecks::Adapters::GitRehearsal::Stages).to receive(:new).and_return(stages)
    @hecks.registry.saga_instances[saga].clear
    @hecks.registry.saga_log.clear
    @boardings = []
    stub_outside
    Hecks::Adapters::MainIntegration::CodeWatch.fingerprint = instance_double(
      Hecks::Adapters::Driving::Resident::Fingerprint, current: 1
    )
  end

  after do
    [Hecks::Adapters::MainVerification, Hecks::Adapters::MainBoarding, Hecks::Adapters::CiRuns].each { |a| a.runner = nil }
    Hecks::Adapters::MainBoarding.train_root = nil
    Hecks::Adapters::MainVerification.log_directory = nil
    Hecks::Adapters::MainIntegration::CodeWatch.fingerprint = nil
    FileUtils.remove_entry(dir)
  end

  def git(*args, chdir: repo)
    out, status = Open3.capture2e("git", "-c", "user.name=t", "-c", "user.email=t@t", *args, chdir: chdir)
    raise out unless status.success?

    out
  end

  def open_repository
    git("init", "--bare", "-b", "main", File.join(dir, "origin.git"), chdir: dir)
    git("clone", "-q", File.join(dir, "origin.git"), repo, chdir: dir)
    git("commit", "--allow-empty", "-m", "start")
    git("push", "-q", "origin", "main")
  end

  def launch(*argv)
    outer = Thread.current[:hecks_reaction_depth]
    Thread.current[:hecks_reaction_depth] = 0
    Hecks::Adapters::Driving::CliRunner.call(runtime: @hecks, argv: argv, program: "hecks")
  ensure
    Thread.current[:hecks_reaction_depth] = outer
  end

  def land(file)
    branch = "feature-#{SecureRandom.hex(3)}"
    tree = File.join(dir, branch)
    git("worktree", "add", "-q", "-b", branch, tree)
    File.write(File.join(tree, file), SecureRandom.hex)
    git("add", ".", chdir: tree)
    git("commit", "-m", file, chdir: tree)
    launch("landing.land!", "run=l-#{SecureRandom.hex(4)}", "checkout.value=#{tree}", "branch.value=#{branch}",
           "--confirm", "--wait")
    git("rev-parse", "main").strip
  end

  def advance(times = 1) = times.times { launch("Integration.advance!", "--confirm", "--wait") }

  # One beat's read of every pushed or watched run, with nobody advancing.
  def poll
    Hecks::Runtime::Dispatcher.new(@hecks.registry).dispatch_flat("Hecks::Integration.Poll", run: "beat-#{SecureRandom.hex(3)}")
  end

  def stage(landed) = @hecks.registry.saga_instances[saga].dig(landed, :state)

  def stub_outside
    @pulls = {}
    Hecks::Adapters::MainVerification.runner = ->(argv, chdir:) { argv.include?("gate_run.gate!") ? [true, "green"] : [true, chdir] }
    Hecks::Adapters::MainVerification.log_directory = File.join(dir, "verification-logs")
    Hecks::Adapters::MainBoarding.runner = method(:train)
    Hecks::Adapters::MainBoarding.train_root = dir
    Hecks::Adapters::CiRuns.runner = ->(argv, **) { github(argv) }
  end

  def train(argv, chdir:)
    return [true, argv.include?("rev-parse") ? "#{git("rev-parse", "main").strip}\n" : ""] if argv.first == "git"

    @boardings << argv
    [true, "#{JSON.generate(state: { status: "pushed", pushed: git("rev-parse", "main").strip })}\n"]
  end

  # A pull request reads open unless the spec has resolved it, keyed by the commit in its branch.
  def github(argv)
    return [true, JSON.generate(pull_of(argv[3].to_s))] if argv[1..2] == %w[pr view]

    [true, JSON.generate([{ databaseId: 7, status: "completed", conclusion: "success" }])]
  end

  def pull_of(branch)
    sha = @pulls.keys.find { |landed| branch.include?(landed[0, 12]) }
    sha ? @pulls[sha] : { number: 12, state: "OPEN", mergeCommit: nil }
  end

  def resolve(landed, state)
    @pulls[landed] = { number: 12, state: state, mergeCommit: state == "MERGED" ? { oid: "d" * 40 } : nil }
  end

  # The earlier run pushed behind an open pull request, the later one verified and waiting.
  def held_behind_open_pull_request
    first = land("first.rb")
    advance(3)
    second = land("second.rb")
    advance(2)
    [first, second]
  end

  it "boards the held tip when the pull request ahead merges, on the next observation", :aggregate_failures do
    first, second = held_behind_open_pull_request
    expect(stage(second)).to eq("verified")
    resolve(first, "MERGED")
    poll
    expect([stage(first), stage(second)]).to eq(%w[green pushed])
  end

  it "boards the held tip when the pull request ahead closes unmerged", :aggregate_failures do
    first, second = held_behind_open_pull_request
    resolve(first, "CLOSED")
    poll
    expect([stage(first), stage(second)]).to eq(%w[needs_human pushed])
  end

  it "boards nothing while the pull request ahead is still open" do
    _first, second = held_behind_open_pull_request
    poll
    expect(stage(second)).to eq("verified")
  end

  it "boards a tip once, however many observations follow" do
    first, = held_behind_open_pull_request
    resolve(first, "MERGED")
    2.times { poll }
    expect(@boardings.size).to eq(2)
  end

  # Two pull requests stand open (the second is marked pushed by hand) and a third tip is verified.
  def two_open_and_a_third_held
    first, second = held_behind_open_pull_request
    @hecks.registry.saga_instances[saga][second][:state] = "pushed"
    third = land("third.rb")
    advance(2)
    [first, third]
  end

  it "does not board a third tip when one of two open pull requests merges", :aggregate_failures do
    first, third = two_open_and_a_third_held
    resolve(first, "MERGED")
    poll
    expect([stage(first), stage(third)]).to eq(%w[green verified])
  end

  # GitHub squashes the first pull request into origin/main, and the checkout's pull rebases the
  # held tip onto it: the tip's commit is rewritten, so the run keyed by the old sha is superseded.
  def squash_first_and_pull(first)
    other = File.join(dir, "other")
    git("clone", "-q", File.join(dir, "origin.git"), other, chdir: dir)
    File.write(File.join(other, "first.rb"), git("show", "#{first}:first.rb"))
    git("add", ".", chdir: other)
    git("commit", "-m", "Train: main at first (#12)", chdir: other)
    git("push", "-q", "origin", "main", chdir: other)
    git("pull", "-q", "--rebase", "origin", "main")
    resolve(first, "MERGED")
  end

  def rewritten_tip(old) = git("rev-parse", "main").strip.tap { |head| expect(head).not_to eq(old) }

  it "opens a run for a held tip the pull rewrote, and boards it", :aggregate_failures do
    first, second = held_behind_open_pull_request
    squash_first_and_pull(first)
    head = rewritten_tip(second)
    2.times { poll }
    expect([stage(second), stage(head)]).to eq(%w[superseded ci_running])
  end

  it "opens no second run for the rewritten tip however many observations follow" do
    first, second = held_behind_open_pull_request
    squash_first_and_pull(first)
    head = rewritten_tip(second)
    3.times { poll }
    expect(@hecks.registry.saga_instances[saga].keys.count(head)).to eq(1)
  end
end
