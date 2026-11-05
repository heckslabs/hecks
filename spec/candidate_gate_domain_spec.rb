require "spec_helper"
require "fileutils"
require "json"
require "open3"
require "securerandom"
require "tmpdir"
require "hecks/hecks/adapters/candidate_gating"
require "hecks/hecks/adapters/git_train"
require "hecks/hecks/adapters/dispatching/work_items"

# The candidate gate through the booted Hecks domain (ADR 0181), in Memory: a boarding with the
# gate on is recorded as queued, an observation records the candidate red, a rejection records
# what it kept and files the red Work items in Tickets, and the switch is recorded. The
# repository is a throwaway one with a bare remote; GitHub is a fake.
RSpec.describe "the candidate gate through the Hecks domain" do
  let(:dir) { File.realpath(Dir.mktmpdir("hecks-candidate-domain")) }
  let(:repo) { File.join(dir, "main") }
  let(:runs) { [] }

  before(:all) do
    @hecks = Hecks.boot(File.join(InMemoryDomain::ROOT, "lib/hecks/hecks"), install_driving: false,
                                                                            environment:     HecksMemoryEnvironment::NAME)
  end

  before do
    open_repository
    Hecks::Adapters::CandidateGating.runner = ->(argv, **) { github(argv) }
    allow(Hecks::Adapters::GitTrain).to(receive(:new).and_wrap_original do |original, **kw|
      original.call(**kw, runner: ->(argv, **) { github(argv) })
    end)
  end

  after do
    Hecks::Adapters::CandidateGating.runner = nil
    FileUtils.remove_entry(dir)
  end

  def git(*args, chdir: repo)
    out, status = Open3.capture2e("git", "-c", "user.name=Coder One", "-c", "user.email=t@t", *args, chdir: chdir)
    raise out unless status.success?

    out.strip
  end

  def open_repository
    git("init", "--bare", "-b", "main", File.join(dir, "origin.git"), chdir: dir)
    git("clone", "-q", File.join(dir, "origin.git"), repo, chdir: dir)
    git("commit", "--allow-empty", "-m", "start")
    git("push", "-q", "origin", "main")
    git("config", Hecks::Adapters::CandidateGate::CONFIG, "true")
  end

  # A fake GitHub: the run list answers `runs`; a run view answers one failed shard and a green job.
  def github(argv)
    return [true, JSON.generate(runs)] if argv[1..2] == %w[run list]

    jobs = [{ "name" => "rspec_impl (3)", "conclusion" => "failure" }, { "name" => "lint", "conclusion" => "success" }]
    [true, JSON.generate("jobs" => jobs)]
  end

  def commit(message)
    File.write(File.join(repo, "#{message}.rb"), SecureRandom.hex)
    git("add", ".")
    git("commit", "-q", "-m", message)
    git("rev-parse", "main")
  end

  def launch(*argv)
    outer = Thread.current[:hecks_reaction_depth]
    Thread.current[:hecks_reaction_depth] = 0
    Hecks::Adapters::Driving::CliRunner.call(runtime: @hecks, argv: argv, program: "hecks")
  ensure
    Thread.current[:hecks_reaction_depth] = outer
  end

  def board = launch("SendTrain.board!", "run=b-#{SecureRandom.hex(4)}", "checkout.value=#{repo}", "--confirm", "--wait")

  def observe = launch("candidate", "Candidate.observe!", "run=o-#{SecureRandom.hex(4)}", "checkout.value=#{repo}", "--wait")

  def reject
    launch("candidate", "Candidate.reject!", "run=r-#{SecureRandom.hex(4)}", "checkout.value=#{repo}", "--confirm", "--wait")
  end

  def event(name) = @hecks.registry.event_log.reverse.find { |logged| logged.name == name }

  def payload(name) = Hecks::Runtime::Value.materialize(event(name).payload)

  def remote(ref) = git("ls-remote", "origin", ref).split.first

  def red_run = runs << { "databaseId" => 9, "status" => "completed", "conclusion" => "failure" }

  def planned = Hecks::Adapters::Dispatching::WorkItems.new(@hecks.registry).planned.map(&:key)

  it "records a boarding with the gate on as queued, on the candidate ref", :aggregate_failures do
    sha = commit("feature")
    board

    expect(payload("BoardingQueued")).to include(boarded: { value: sha })
    expect([remote("refs/heads/candidate"), remote("refs/heads/main")]).to eq([sha, git("rev-parse", "main~1")])
  end

  it "records a red candidate with its run and failed jobs" do
    commit("feature")
    board
    red_run
    observe

    expect(payload("CandidateRed")).to include(ci_run: { value: "9" }, jobs: { value: "rspec_impl (3)" })
  end

  # Boards a feature, has CI fail on it and rejects the candidate; answers the feature's commit.
  def rejected
    sha = commit("feature")
    board
    red_run
    reject
    sha
  end

  it "records the rejection with the branch that keeps the commits and the coders", :aggregate_failures do
    sha = rejected

    expect(payload("CandidateRejected")).to include(branch: { value: "rejected/#{sha[0, 12]}" }, authors: { value: "Coder One" })
    expect(git("rev-parse", "main")).to eq(git("rev-parse", "origin/main"))
  end

  it "files one red Work item per failing cause in Tickets" do
    rejected

    expect(planned).to include(a_string_starting_with("red-rspec_impl-"))
  end

  it "records the switch" do
    launch("candidate", "Candidate.disable!", "run=s-#{SecureRandom.hex(4)}", "checkout.value=#{repo}", "--confirm", "--wait")

    expect(payload("GateSwitched")).to include(setting: { value: "off" })
  end
end
