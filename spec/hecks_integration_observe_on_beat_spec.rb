require "spec_helper"
require "json"
require "open3"
require "securerandom"
require "tmpdir"

# A train pull request's verdict is noticed by the clock alone: a beat reads the CI run of each
# pushed or watched run (`ObserveOnHeartbeat`) and, once GitHub has merged the pull request, the
# checkout that boarded it is brought level with origin/main, with no `Integration.advance!`. The
# domain is in Memory; the repository is a throwaway one with a bare remote, GitHub is a fake whose
# pull request opens and then merges, and every port a beat reaches but these three is quiet.
RSpec.describe "noticing a train pull request's verdict on the clock's beat" do
  let(:dir) { File.realpath(Dir.mktmpdir("hecks-observe-on-beat")) }

  # A port a beat reaches that this spec does not wire: every ask is refused as quiet.
  let(:quiet) do
    Object.new.tap do |port|
      port.define_singleton_method(:method_missing) { |*| raise Hecks::Adapters::ConsoleCapture::Failure, "quiet" }
      port.define_singleton_method(:respond_to_missing?) { |*| true }
    end
  end

  before(:all) { @hecks = boot_hecks_in_memory }

  before do
    open_repositories
    @pull = { number: 12, state: "OPEN" }
    @asked = []
    @pulls_before = @hecks.registry.event_log.count { |logged| logged.name == "PullRequested" }
    @hecks.registry.saga_instances["MainIntegration"].clear
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

  def commit(where, file, content = SecureRandom.hex)
    File.write(File.join(where, file), content)
    git("add", ".", chdir: where)
    git("commit", "-q", "-m", file, chdir: where)
    git("rev-parse", "HEAD", chdir: where)
  end

  # Local main boards one commit and the run stands pushed; GitHub squashes it into a new commit
  # on origin/main, so local main stands ahead by one and behind by one once the request merges.
  def boarded_run(state: "pushed")
    boarded = commit(repo, "boarded.txt", "boarded")
    @hecks.registry.saga_instances["MainIntegration"][boarded] = { state: state, memory: { checkout: repo } }
    boarded
  end

  def merge_pull_request
    File.write(File.join(other, "boarded.txt"), "boarded")
    git("add", ".", chdir: other)
    git("commit", "-q", "-m", "Train: main at boarded (#12)", chdir: other)
    git("push", "-q", "origin", "main", chdir: other)
    @pull = { number: 12, state: "MERGED", mergeCommit: { oid: git("rev-parse", "HEAD", chdir: other) } }
  end

  def github(argv)
    @asked << argv[1..2]
    return [true, JSON.generate(@pull)] if argv[1..2] == %w[pr view]
    return [true, JSON.generate(jobs: [{ name: "rspec", conclusion: "failure" }])] if argv[1..2] == %w[run view]

    [true, JSON.generate([{ databaseId: 7, status: @run_status || "completed", conclusion: @conclusion || "success" }])]
  end

  def real_ports = %w[Integrating CiRuns WorktreeAdding]

  def stand_in
    lambda do |port, asked|
      return quiet unless real_ports.include?(port)

      klass = Hecks::Runtime::AdapterLookup.adapter_class(@hecks.registry, port, asked: asked)
      Hecks::Runtime::AdapterLookup.build(klass, registry: @hecks.registry)
    end
  end

  def beat
    outer = Thread.current[:hecks_reaction_depth]
    Thread.current[:hecks_reaction_depth] = 0
    Hecks::Runtime::AdapterLookup.standing_in(stand_in) do
      Hecks::Runtime::Dispatcher.new(@hecks.registry)
                                .dispatch_flat("Hecks::Heartbeat.Beat", beat: { value: "b-#{SecureRandom.hex(3)}" })
    end
  ensure
    Thread.current[:hecks_reaction_depth] = outer
  end

  def ahead_behind = git("rev-list", "--left-right", "--count", "main...origin/main").split.map(&:to_i)

  def stage(landed) = @hecks.registry.saga_instances["MainIntegration"].dig(landed, :state)

  # Pulls asked since the example began: the booted domain's event log is shared by the examples.
  def pulls = @hecks.registry.event_log.count { |logged| logged.name == "PullRequested" } - @pulls_before

  it "waits while the pull request is open", :aggregate_failures do
    boarded = boarded_run
    beat
    expect(stage(boarded)).to eq("ci_running")
    expect(pulls).to eq(0)
  end

  def beat_through_a_merge
    boarded = boarded_run
    beat
    merge_pull_request
    beat
    boarded
  end

  it "records the verdict once the pull request merges, on beats alone" do
    expect(stage(beat_through_a_merge)).to eq("green")
  end

  it "brings main level once the pull request merges, on beats alone" do
    beat_through_a_merge
    expect(git("fetch", "-q", "origin") && ahead_behind).to eq([0, 0])
  end

  it "pulls once, however many beats follow the verdict" do
    boarded_run
    merge_pull_request
    3.times { beat }
    expect(pulls).to eq(1)
  end

  it "pulls once when an advance follows the beat that read the verdict" do
    boarded_run
    merge_pull_request
    beat
    Hecks::Adapters::MainIntegration.new(registry: @hecks.registry).step(confirm: false)
    expect(pulls).to eq(1)
  end

  it "pulls main when CI on the merge commit failed" do
    @conclusion = "failure"
    boarded_run
    merge_pull_request
    beat
    expect(git("fetch", "-q", "origin") && ahead_behind).to eq([0, 0])
  end

  def open_with_failed_check
    { number: 12, state: "OPEN", statusCheckRollup: [{ status: "COMPLETED", conclusion: "FAILURE" }] }
  end

  # A check fails on the open pull request, a rerun passes, and the pull request is still open.
  def beats_through_a_failed_check_and_a_rerun
    @pull = open_with_failed_check
    boarded = boarded_run
    2.times { beat }
    @pull = { number: 12, state: "OPEN" }
    beat
    boarded
  end

  it "keeps watching a pull request whose check failed, pulling nothing", :aggregate_failures do
    boarded = beats_through_a_failed_check_and_a_rerun
    expect(stage(boarded)).to eq("ci_running")
    expect(pulls).to eq(0)
  end

  it "pulls once the pull request merges after a failed check and a rerun" do
    boarded = beats_through_a_failed_check_and_a_rerun
    merge_pull_request
    beat
    expect([stage(boarded), pulls]).to eq(["green", 1])
  end

  # The beats come from outside (no Ticker chain is started anywhere in this spec): the pull
  # request's check has finished red, the first beat records the failure and reruns it once.
  it "records a finished red check once and reruns it once, on beats from outside", :aggregate_failures do
    @pull = open_with_failed_check
    boarded_run
    seen = logged_since { 3.times { beat } }
    expect(%w[TrainPrFailed TrainPrRerun TickerRequested].map { |name| seen.count(name) }).to eq([1, 1, 0])
  end

  # The names of the events the block recorded: the examples share the booted domain's event log.
  def logged_since
    before = @hecks.registry.event_log.size
    yield
    @hecks.registry.event_log.map(&:name).drop(before)
  end

  def beats_after_a_merge_with_ci_running
    @run_status = "in_progress"
    boarded = boarded_run
    merge_pull_request
    3.times { beat }
    boarded
  end

  it "pulls main at the merge, once, while CI on the merge commit is still running", :aggregate_failures do
    boarded = beats_after_a_merge_with_ci_running
    expect([stage(boarded), pulls]).to eq(["merged", 1])
    expect(git("fetch", "-q", "origin") && ahead_behind).to eq([0, 0])
  end

  it "records the verdict of the merge commit after the pull without pulling again", :aggregate_failures do
    boarded = beats_after_a_merge_with_ci_running
    @run_status = "completed"
    beat
    expect([stage(boarded), pulls]).to eq(["green", 1])
  end

  it "ends in red when CI on the merge commit fails after the pull, without pulling again", :aggregate_failures do
    boarded = beats_after_a_merge_with_ci_running
    @run_status = "completed"
    @conclusion = "failure"
    beat
    expect([stage(boarded), pulls]).to eq(["red", 1])
  end

  it "reads nothing on a beat with no run in flight" do
    boarded_run(state: "landed")
    beat
    expect(@asked).to be_empty
  end

  it "does not verify or board a landed run" do
    boarded = boarded_run(state: "landed")
    beat
    expect(stage(boarded)).to eq("landed")
  end
end
