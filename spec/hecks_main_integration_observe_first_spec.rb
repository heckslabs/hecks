require "spec_helper"
require "fileutils"
require "json"
require "open3"
require "tmpdir"

# A verified run that waits on an earlier push boards in the advance that sees the push turn
# green, with no landing between: the pushed run is observed before the others are taken, whatever
# order the saga lists the runs in. The domain is in Memory; the repository is a throwaway one with
# a bare remote, and GitHub and the push train are fakes.
RSpec.describe "an advance observes the pushed run before it boards the run behind it" do
  let(:dir) { File.realpath(Dir.mktmpdir("hecks-observe-first")) }
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

    @boardings << argv
    [true, "#{JSON.generate(state: { status: "pushed", pushed: git("rev-parse", "main").strip })}\n"]
  end

  def github(argv)
    return [true, JSON.generate(@pull)] if argv[1..2] == %w[pr view]

    [true, JSON.generate([{ databaseId: 7, status: "completed", conclusion: "success" }])]
  end

  # The earlier run pushed behind an open pull request, the later one verified and waiting, and
  # the saga listing the waiting run first.
  def waiting_run_listed_first
    @pull = { number: 12, state: "OPEN", mergeCommit: nil }
    first = land("first.rb")
    advance(3)
    second = land("second.rb")
    advance(2)
    instances = @hecks.registry.saga_instances[saga]
    instances[first] = instances.delete(first)
    [first, second]
  end

  it "boards the waiting run when the earlier push turns green, in one advance", :aggregate_failures do
    first, second = waiting_run_listed_first
    @pull = { number: 12, state: "MERGED", mergeCommit: { oid: "d" * 40 } }
    advance
    expect(stage(first)).to eq("green")
    expect(stage(second)).to eq("pushed")
  end
end
