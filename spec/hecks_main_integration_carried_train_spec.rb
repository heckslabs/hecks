require "spec_helper"
require "fileutils"
require "json"
require "open3"
require "tmpdir"
require_relative "support/rest_pull_view"

# A pushed run whose commit rode a train named for a later commit is judged by that train's pull
# request, found by the commit: once it merged with CI green on its merge commit the run turns green
# and frees the line, while it is open the run still holds it. When the line is free, the newest
# verified landing boards. The domain is in Memory; the repository is a throwaway one with a bare
# remote, and GitHub and the push train are fakes.
RSpec.describe "an advance judges a run by the train that carried it and boards the newest landing" do
  let(:dir) { File.realpath(Dir.mktmpdir("hecks-carried-train")) }
  let(:repo) { File.join(dir, "main") }
  let(:stages) { instance_double(Hecks::Adapters::GitRehearsal::Stages, run: []) }
  let(:saga) { "MainIntegration" }

  before(:all) { @hecks = boot_hecks_in_memory }

  before do
    open_repository
    allow(Hecks::Adapters::GitRehearsal::Stages).to receive(:new).and_return(stages)
    @hecks.registry.saga_instances[saga].clear
    @hecks.registry.saga_log.clear
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
    Hecks::Adapters::CiRuns::PullCache.shared.clear
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

  def stage(landed) = @hecks.registry.saga_instances[saga].dig(landed, :state)

  def stub_outside
    Hecks::Adapters::MainVerification.runner = ->(argv, chdir:) { argv.include?("gate_run.gate!") ? [true, "green"] : [true, chdir] }
    Hecks::Adapters::MainVerification.log_directory = File.join(dir, "verification-logs")
    Hecks::Adapters::MainBoarding.runner = method(:train)
    Hecks::Adapters::MainBoarding.train_root = dir
    Hecks::Adapters::CiRuns.runner = ->(argv, **) { github(argv) }
  end

  def train(argv, chdir:)
    return [true, argv.include?("rev-parse") ? "#{git("rev-parse", "main").strip}\n" : ""] if argv.first == "git"

    [true, "#{JSON.generate(state: { status: "pushed", pushed: git("rev-parse", "main").strip })}\n"]
  end

  # CI has a run, green, only on the merge commit; no run names a landed commit.
  def github(argv)
    return [true, RestPullView.answer(argv, @pull)] if RestPullView.api?(argv)

    [true, JSON.generate(argv.include?(merge_commit) ? [{ databaseId: 7, status: "completed", conclusion: "success" }] : [])]
  end

  def merge_commit = "d" * 40

  # The train pull request, open; a `branch` names it for a later commit than the one it carries.
  def open_pull(branch = nil)
    @pull = { number: 12, state: "OPEN", mergeCommit: nil, headRefName: branch }.compact
  end

  # The pull request merges; the next advance is a new process, which holds no earlier read.
  def merge_pull_request
    @pull = @pull.merge(state: "MERGED", mergeCommit: { oid: merge_commit })
    Hecks::Adapters::CiRuns::PullCache.shared.clear
  end

  # The first run pushed and watched, then each later landing verified and waiting behind it.
  def pushed_then_waiting(*files)
    first = land("first.rb")
    advance(3)
    [first] + files.map { |file| land(file).tap { advance(2) } }
  end

  it "turns a run carried by a train named for a later commit green, and boards the next", :aggregate_failures do
    open_pull("train/main-#{"e" * 12}")
    first, second = pushed_then_waiting("second.rb")
    merge_pull_request
    advance
    expect([stage(first), stage(second)]).to eq(%w[green pushed])
  end

  it "holds the line while the train that carries the run is open" do
    open_pull("train/main-#{"e" * 12}")
    first, second = pushed_then_waiting("second.rb")
    advance
    expect([stage(first), stage(second)]).to eq(%w[ci_running verified])
  end

  it "boards the newest verified landing when the line frees" do
    open_pull
    _, second, third = pushed_then_waiting("second.rb", "third.rb")
    merge_pull_request
    advance
    expect([stage(second), stage(third)]).to eq(%w[verified pushed])
  end
end
