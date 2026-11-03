require "spec_helper"
require "fileutils"
require "json"
require "open3"
require "securerandom"
require "tmpdir"
require "hecks/hecks/adapters/in_process_operations/tap_log"
require "hecks/hecks/adapters/red_flagging"
require "hecks/runtime/event_tap"

# Main's red flag over one CI cycle, with GitHub's own records (the jobs of CI run 41540218609 and
# the run rows of 2026-11-02): the red run raises it, a landing that is not a red row's fix is
# refused by name, the fix lands and records its tip, the same red run reported again changes
# nothing, the green run lowers it and landing resumes. Every session hears it: two readers of the
# event tap see the same events with the flag, commit, run and jobs, and the owner's desktop is
# told. The domain is in Memory, the repository a throwaway one, GitHub a stand-in fed the records.
RSpec.describe "the red flag over a real CI cycle" do
  # Named for this file: top-level constants land on Object, so other specs must not reuse these.
  CYCLE_FIXTURES = File.expand_path("fixtures/red_flag", __dir__) unless defined?(CYCLE_FIXTURES)
  CYCLE_JOBS = JSON.parse(File.read(File.join(CYCLE_FIXTURES, "run_41540218609_jobs.json"))) unless defined?(CYCLE_JOBS)
  CYCLE_RUNS = JSON.parse(File.read(File.join(CYCLE_FIXTURES, "main_runs.json"))) unless defined?(CYCLE_RUNS)
  CYCLE_DOMAIN = File.join(InMemoryDomain::ROOT, "lib/hecks/hecks") unless defined?(CYCLE_DOMAIN)

  let(:dir) { File.realpath(Dir.mktmpdir("hecks-red-flag-cycle")) }
  let(:repo) { File.join(dir, "main") }
  let(:red) { CYCLE_RUNS.find { |run| run["conclusion"] == "failure" } }
  let(:green) { CYCLE_RUNS.find { |run| run["conclusion"] == "success" } }

  before(:all) do
    @hecks = Hecks.boot(CYCLE_DOMAIN, install_driving: false, environment: HecksMemoryEnvironment::NAME)
  end

  before do
    open_repository
    @runs = [red]
    @dispatched = []
    Hecks::Adapters::RedFlagging.runner = ->(argv, **) { github(argv) }
    Hecks::Adapters::RedFlagKick.effects = cycle_effects
    QuietDesktopAlert.reset!
  end

  after do
    Hecks::Adapters::RedFlagging.runner = nil
    Hecks::Adapters::RedFlagKick.effects = nil
    @hecks.registry.event_log.observer = nil
    FileUtils.remove_entry(dir)
  end

  def git(*args, chdir: repo)
    out, status = Open3.capture2e("git", "-c", "user.name=t", "-c", "user.email=t@t", *args, chdir: chdir)
    raise out unless status.success?

    out.strip
  end

  def open_repository
    git("init", "--bare", "-b", "main", File.join(dir, "origin.git"), chdir: dir)
    git("clone", "-q", File.join(dir, "origin.git"), repo, chdir: dir)
    # The kick's revert commits with the repository's own identity, which a CI runner lacks.
    git("config", "user.name", "t")
    git("config", "user.email", "t@t")
    git("commit", "--allow-empty", "-m", "start")
    git("push", "-q", "origin", "main")
  end

  # GitHub as `gh` answers it: the run list, newest first, the successes alone when asked, and the
  # real jobs of the red run.
  def github(argv)
    return [true, JSON.generate(CYCLE_JOBS)] if argv[1..2] == %w[run view]
    return [true, JSON.generate(@runs.select { |run| run["conclusion"] == "success" }.first(1))] if argv.include?("success")

    [true, JSON.generate(@runs.first(1))]
  end

  # The kick's steps, with the train, the coder and the quick gate left out: the landing is the real
  # local one, so the fix's tip is recorded on the flag as it is in production.
  def cycle_effects
    {
      land:     ->(**args) { cycle_dispatch("Hecks::Landing.Land", args) },
      board:    ->(**) {},
      brief:    ->(**args) { "brief for #{args[:work]}" },
      dispatch: ->(**args) { @dispatched << args },
      retire:   ->(**args) { git("worktree", "remove", "--force", args[:checkout]) && git("branch", "-D", args[:branch]) }
    }
  end

  def cycle_dispatch(verb, args)
    depth = Thread.current[:hecks_reaction_depth]
    Thread.current[:hecks_reaction_depth] = 0
    Hecks::Runtime::Dispatcher.new(@hecks.registry).dispatch_flat(verb, args)
  ensure
    Thread.current[:hecks_reaction_depth] = depth
  end

  def launch(*argv)
    outer = Thread.current[:hecks_reaction_depth]
    Thread.current[:hecks_reaction_depth] = 0
    Hecks::Adapters::Driving::CliRunner.call(runtime: @hecks, argv: argv, program: "hecks")
  ensure
    Thread.current[:hecks_reaction_depth] = outer
  end

  # A launch whose refusal is the point: the reason is recorded as an event, so the exit is
  # swallowed.
  def attempt(*argv)
    launch(*argv)
  rescue SystemExit, StandardError
    nil
  end

  def sync = launch("RedFlag.sync!", "run=s-#{SecureRandom.hex(4)}", "checkout.value=#{repo}", "--wait")

  def check_in
    launch("RedFlag.check_in!", "run=c-#{SecureRandom.hex(4)}", "session.value=s1", "taking.value=red-ci-rspec-shards",
           "checkout.value=#{repo}", "--wait")
  end

  # The red run, then the green one on top of it.
  def red_then_green
    sync
    @runs = [green, red]
    sync
  end

  def land(branch)
    tree = File.join(dir, branch.tr("/", "_"))
    git("worktree", "add", "-q", "-b", branch, tree)
    File.write(File.join(tree, "#{branch.tr("/", "_")}.txt"), SecureRandom.hex)
    git("add", ".", chdir: tree)
    git("commit", "-q", "-m", branch, chdir: tree)
    attempt("landing.land!", "run=l-#{SecureRandom.hex(4)}", "checkout.value=#{tree}", "branch.value=#{branch}",
            "--confirm", "--wait")
    git("rev-parse", "main")
  end

  def flag
    path = File.join(repo, ".git", "hecks-red-flag.json")
    JSON.parse(File.read(path)) if File.exist?(path)
  end

  def events(name) = @hecks.registry.event_log.select { |event| event.name == name }

  def payload(event) = Hecks::Runtime::Value.materialize(event.payload)

  def refusal(name) = payload(events(name).last).dig(:refusal, :value).to_s

  # The tap every session follows, pointed at this example's own file: the Memory overlay the
  # specs boot with declares none, so the example installs the world's tap by hand.
  def tap_into(path)
    tap = Hecks::Runtime::EventTap.new(path: path, payloads: %w[RedFlag])
    @hecks.registry.event_log.observer = tap.method(:event)
  end

  # One reader's view of the red flag's events, as `Operation.follow` reads the tap.
  def reader(path)
    Hecks::Adapters::InProcessOperations::TapLog.new(path).events.select { |event| event.aggregate.end_with?("RedFlag") }
  end

  # The payload a reader saw for the named event, as plain data.
  def seen(view, name)
    event = view.find { |held| held.name == name } or raise "no #{name} among #{view.map(&:name).inspect}"
    event.payload
  end

  it "raises the flag from the red run, carrying the run id and the failed jobs", :aggregate_failures do
    sync

    expect(flag).to include("id" => "flag-2dc207c705", "commit" => red["headSha"])
    expect(flag["runs"].first).to include("ci_run" => "41540218609")
    expect(flag["runs"].first["jobs"]).to include("rspec_impl / rspec_shard (8)", "rspec_postgres_io_parallel")
    expect(payload(events("RedFlagRaised").last).dig(:jobs, :value)).to include("rspec_impl / rspec_shard (1)")
  end

  it "refuses a landing that is not a red row's fix, naming the flag", :aggregate_failures do
    sync
    before = git("rev-parse", "main")

    expect(land("feature-#{SecureRandom.hex(3)}")).to eq(before)
    expect(refusal("MergeRefused")).to include("main is red: flag flag-2dc207c705")
  end

  it "lands the fix of a red row while the flag stands and records its tip for the train", :aggregate_failures do
    sync
    tip = land("red-ci-rspec-shards")

    expect(flag).to include("fix_tip" => tip, "fix_branch" => "red-ci-rspec-shards")
    expect(tip).not_to eq(git("rev-parse", "origin/main"))
  end

  it "changes nothing when the same red run is reported again", :aggregate_failures do
    sync
    unchanged = events("RedFlagUnchanged").size
    sync

    expect(flag["runs"].size).to eq(1)
    expect(events("RedFlagUnchanged").size).to eq(unchanged + 1)
  end

  it "lowers the flag on the green run, and landing resumes", :aggregate_failures do
    red_then_green

    expect(flag).to be_nil
    expect(payload(events("RedFlagCleared").last).dig(:flag, :value)).to eq("flag-2dc207c705")
    expect(land("feature-#{SecureRandom.hex(3)}")).not_to eq(git("rev-parse", "origin/main"))
  end

  it "tells the owner on the desktop when the flag goes up and when it comes down", :aggregate_failures do
    red_then_green
    said = QuietDesktopAlert.shown.flatten.join("\n")

    expect(said).to include("main is red: flag-2dc207c705", "CI run 41540218609", "rspec_impl / rspec_shard (8)")
    expect(said).to include("main is green again: flag-2dc207c705")
  end

  # Points the tap at this example's file, raises the flag and checks in, then answers what
  # `readers` readers of the tap see.
  def watched(readers)
    path = File.join(dir, "events.jsonl")
    tap_into(path)
    sync
    check_in
    Array.new(readers) { reader(path) }
  end

  it "reaches every session through the event tap: a second reader sees what the first saw", :aggregate_failures do
    first, second = watched(2)

    expect(second.map(&:to_h)).to eq(first.map(&:to_h))
    expect(first.map(&:name)).to include("RedFlagRaised", "RedFlagCheckedIn")
  end

  it "carries the flag, commit, run, jobs and the helper in the events a reader sees", :aggregate_failures do
    view = watched(1).first

    expect(seen(view, "RedFlagRaised"))
      .to include("flag" => { "value" => "flag-2dc207c705" }, "ci_run" => { "value" => "41540218609" })
    expect(seen(view, "RedFlagCheckedIn"))
      .to include("session" => { "value" => "s1" }, "taking" => { "value" => "red-ci-rspec-shards" })
  end

  it "keeps every step within the reaction depth bound" do
    seen = @hecks.registry.reaction_log.size
    sync
    land("red-ci-rspec-shards")
    red_then_green

    expect(@hecks.registry.reaction_log.drop(seen).map { |entry| entry[:reason].to_s }.grep(/reaction depth/)).to be_empty
  end

  # A feature lands on a green main and CI turns red on it: the red run raises the flag, and the
  # flag's own event kicks the batch at once, with no hand in it.
  def kick_batch
    green_head = git("rev-parse", "main")
    bad = land("feature-bad")
    @runs = [red.merge("headSha" => bad), green.merge("headSha" => green_head)]
    sync
    [green_head, bad]
  end

  it "kicks the push batch off main as a red row's fix, from the flag's own event", :aggregate_failures do
    green_head, bad = kick_batch

    expect(git("rev-parse", "main^{tree}")).to eq(git("rev-parse", "#{green_head}^{tree}"))
    expect(flag).to include("fix_tip" => git("rev-parse", "main"), "fix_branch" => "red-main-flag-#{bad[0, 10]}")
    expect(flag["kicked"]).to include("reverted" => [bad])
  end

  it "dispatches one coder on the Work row it files, and says so in the event", :aggregate_failures do
    _green_head, bad = kick_batch

    expect(flag["kicked"]).to include("row" => "red-flag-#{bad[0, 10]}")
    expect(payload(events("RedFlagKicked").last).dig(:rows, :value)).to eq("red-flag-#{bad[0, 10]}")
    expect(payload(events("WorkPlanned").last).dig(:work, :value)).to eq("red-flag-#{bad[0, 10]}")
    expect(@dispatched.map { |args| args[:brief] }).to eq(["brief for red-flag-#{bad[0, 10]}"])
  end
end
