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

    [true, JSON.generate([{ databaseId: 7, status: "completed", conclusion: @conclusion || "success" }])]
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
