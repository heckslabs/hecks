require "spec_helper"
require "json"
require "open3"
require "securerandom"
require "tmpdir"

# Local main is brought level with origin/main once a boarded commit's train pull request has
# merged: CI's verdict on the merge commit (PullMainWhenCiPasses, PullMainWhenCiFails) asks
# LinkedTree.PullMain for the checkout that boarded. The domain is in Memory; the repository is a
# throwaway one with a bare remote, and GitHub is a fake that answers the pull request and its run.
RSpec.describe "pulling main after a boarded commit merged" do
  let(:dir) { File.realpath(Dir.mktmpdir("hecks-pull-after-merge")) }

  before(:all) { @hecks = boot_hecks_in_memory }

  before do
    open_repositories
    @pull = nil
    Hecks::Adapters::CiRuns.runner = ->(argv, **) { github(argv) }
  end

  after do
    Hecks::Adapters::CiRuns.runner = nil
    FileUtils.remove_entry(dir)
  end

  def repo = File.join(dir, "repo")

  def other = File.join(dir, "other")

  def git(*args, chdir: repo)
    out, status = Open3.capture2e("git", "-c", "user.name=t", "-c", "user.email=t@t", *args, chdir: chdir)
    raise out unless status.success?

    out.strip
  end

  def open_repositories
    git("init", "--bare", "-b", "main", File.join(dir, "origin.git"), chdir: dir)
    [repo, other].each { |where| git("clone", "-q", File.join(dir, "origin.git"), where, chdir: dir) }
    commit(repo, "README")
    git("push", "-q", "origin", "main")
    git("pull", "-q", "origin", "main", chdir: other)
  end

  # The content is unique, so no two examples share a sha.
  def commit(where, file, content = SecureRandom.hex)
    File.write(File.join(where, file), content)
    git("add", ".", chdir: where)
    git("commit", "-q", "-m", file, chdir: where)
    git("rev-parse", "HEAD", chdir: where)
  end

  # Local main boards one commit; GitHub squashes it into a new commit on origin/main, so local
  # main stands ahead by one and behind by one.
  def board_and_squash
    boarded = commit(repo, "boarded.txt", "boarded")
    File.write(File.join(other, "boarded.txt"), "boarded")
    git("add", ".", chdir: other)
    git("commit", "-q", "-m", "Train: main at #{boarded[0, 9]} (#12)", chdir: other)
    git("push", "-q", "origin", "main", chdir: other)
    @pull = { number: 12, state: "MERGED", mergeCommit: { oid: git("rev-parse", "HEAD", chdir: other) } }
    boarded
  end

  def github(argv)
    return [true, JSON.generate(@pull)] if argv[1..2] == %w[pr view]
    return [true, JSON.generate(jobs: [{ name: "rspec", conclusion: "failure" }])] if argv[1..2] == %w[run view]

    [true, JSON.generate([{ databaseId: 7, status: "completed", conclusion: @conclusion || "success" }])]
  end

  def observe(landed)
    outer = Thread.current[:hecks_reaction_depth]
    Thread.current[:hecks_reaction_depth] = 0
    Hecks::Adapters::Driving::CliRunner.call(runtime: @hecks, program: "hecks",
                                             argv: ["Integration.observe!", "run=o-#{SecureRandom.hex(4)}",
                                                    "landed.value=#{landed}", "checkout.value=#{repo}", "--wait"])
  ensure
    Thread.current[:hecks_reaction_depth] = outer
  end

  def ahead_behind = git("rev-list", "--left-right", "--count", "main...origin/main").split.map(&:to_i)

  def last(event_name, field)
    event = @hecks.registry.event_log.reverse.find { |logged| logged.name == event_name }
    event && Hecks::Runtime::Value.materialize(event.payload).dig(field, :value).to_s
  end

  def fetch = git("fetch", "-q", "origin")

  it "brings main level with a squash merge of its boarded commit", :aggregate_failures do
    observe(board_and_squash)
    expect(ahead_behind).to eq([0, 0])
    expect(last("MainPulled", :report)).to include("carried by squash")
  end

  it "keeps the unpushed commits the pull request did not carry", :aggregate_failures do
    boarded = board_and_squash
    commit(repo, "later.txt", "mine")
    observe(boarded)
    expect(git("log", "--format=%s", "origin/main..main")).to eq("later.txt")
    expect(git("show", "main:later.txt")).to eq("mine")
  end

  it "pulls main when CI on the merge commit failed too" do
    @conclusion = "failure"
    observe(board_and_squash)
    expect(ahead_behind).to eq([0, 0])
  end

  it "refuses a dirty checkout by name and leaves main where it was", :aggregate_failures do
    boarded = board_and_squash
    File.write(File.join(repo, "README"), "edited")
    observe(boarded)
    expect(last("PullDeclinedRecorded", :refusal)).to include("cannot pull main: the checkout has uncommitted changes")
    expect(git("rev-parse", "main")).to eq(boarded)
  end

  it "pulls nothing while the pull request is still open", :aggregate_failures do
    boarded = board_and_squash
    @pull = { number: 12, state: "OPEN" }
    observe(boarded)
    fetch
    expect(ahead_behind).to eq([1, 1])
  end
end
