require "spec_helper"
require "fileutils"
require "json"
require "open3"
require "tmpdir"

# Main is integrated by the MainIntegration saga: a landing onto main starts a run, and each
# `Integration.advance!` dispatches the run's next step. The domain is in Memory; the repository
# is a throwaway one with a bare remote, and the outside is stubbed: the checks a verification
# runs, the push train's copy and GitHub's CI runs.
RSpec.describe "integrating main through the MainIntegration saga" do
  let(:dir) { File.realpath(Dir.mktmpdir("hecks-main-integration")) }
  let(:repo) { File.join(dir, "main") }
  let(:stages) { instance_double(Hecks::Adapters::GitRehearsal::Stages, run: []) }

  before(:all) do
    @hecks = boot_hecks_in_memory
  end

  before do
    open_repository
    allow(Hecks::Adapters::GitRehearsal::Stages).to receive(:new).and_return(stages)
    @hecks.registry.saga_instances[SAGA].clear
    @hecks.registry.saga_log.clear
    @depths = []
    stub_outside
  end

  after do
    [Hecks::Adapters::MainVerification, Hecks::Adapters::MainBoarding, Hecks::Adapters::CiRuns].each { |a| a.runner = nil }
    Hecks::Adapters::MainBoarding.train_root = nil
    FileUtils.remove_entry(dir)
  end

  SAGA = "MainIntegration".freeze unless defined?(SAGA)
  FAILED_JOBS = [{ name: "rspec 1/4", conclusion: "failure" }, { name: "lint", conclusion: "success" }].freeze

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

  # The content is unique so two examples committing in the same second never share a sha: the
  # saga log is keyed by it, and one example's walk would otherwise show up in the next.
  def commit(where, file, message)
    FileUtils.mkdir_p(File.dirname(File.join(where, file)))
    File.write(File.join(where, file), SecureRandom.hex)
    git("add", ".", chdir: where)
    git("commit", "-m", message, chdir: where)
  end

  def launch(*argv)
    outer = Thread.current[:hecks_reaction_depth]
    Thread.current[:hecks_reaction_depth] = 0
    Hecks::Adapters::Driving::CliRunner.call(runtime: @hecks, argv: argv, program: "hecks")
  ensure
    Thread.current[:hecks_reaction_depth] = outer
  end

  # Lands a branch holding one commit and answers the commit main then names.
  def land(file: "feature.rb", message: "feature")
    branch = "feature-#{SecureRandom.hex(3)}"
    tree = File.join(dir, branch)
    git("worktree", "add", "-q", "-b", branch, tree)
    commit(tree, file, message)
    launch("landing.land!", "run=l-#{SecureRandom.hex(4)}", "checkout.value=#{tree}", "branch.value=#{branch}",
           "--confirm", "--wait")
    git("rev-parse", "main").strip
  end

  def advance(times = 1) = times.times { launch("Integration.advance!", "--confirm", "--wait") }

  def stage(landed) = @hecks.registry.saga_instances[SAGA].dig(landed, :state)

  def stages_walked(landed)
    @hecks.registry.saga_log.select { |entry| entry[:process_manager] == SAGA && entry[:instance] == landed && entry[:advanced] }
          .map { |entry| entry[:to] }
  end

  def refusal(event_name)
    event = @hecks.registry.event_log.reverse.find { |logged| logged.name == event_name }
    Hecks::Runtime::Value.materialize(event.payload).dig(:refusal, :value).to_s
  end

  def report(event_name)
    event = @hecks.registry.event_log.reverse.find { |logged| logged.name == event_name }
    Hecks::Runtime::Value.materialize(event.payload).dig(:report, :value).to_s
  end

  def note_depth = @depths << Thread.current[:hecks_reaction_depth].to_i

  def stub_outside(gate: [true, "green"], conclusion: "success", jobs: [])
    Hecks::Adapters::MainVerification.runner = lambda do |argv, chdir:|
      note_depth
      argv.include?("gate_run.gate!") ? gate : [true, "ok in #{chdir}"]
    end
    Hecks::Adapters::MainBoarding.runner = method(:train)
    Hecks::Adapters::MainBoarding.train_root = dir
    Hecks::Adapters::CiRuns.runner = ->(argv, **) { github(argv, conclusion, jobs) }
  end

  def train(argv, chdir:)
    note_depth
    return [true, argv.include?("rev-parse") ? "#{git("rev-parse", "main").strip}\n" : ""] if argv.first == "git"

    (@boardings ||= []) << argv
    [true, "#{JSON.generate(state: { status: "pushed", pushed: git("rev-parse", "main").strip })}\n"]
  end

  def github(argv, conclusion, jobs)
    note_depth
    return pull_request_view if argv[1..2] == %w[pr view]
    return [true, JSON.generate(jobs: jobs)] if argv[1..2] == %w[run view]

    (@ci_commits ||= []) << argv[argv.index("--commit") + 1]
    [true, JSON.generate([{ databaseId: 7, status: "completed", conclusion: conclusion }])]
  end

  # The train's pull request as GitHub holds it: none by default (a plain push), or the state a
  # spec sets in `@pull`.
  def pull_request_view
    return [false, "no pull requests found for branch \"train/main-x\""] unless @pull

    [true, JSON.generate(@pull)]
  end

  def merged_as(sha) = { number: 12, state: "MERGED", mergeCommit: { oid: sha } }

  it "judges CI on the commit GitHub merged the train pull request as", :aggregate_failures do
    @pull = merged_as("f" * 40)
    landed = land
    advance(3)
    expect(stage(landed)).to eq("green")
    expect(@ci_commits).to all(eq("f" * 40))
  end

  it "ends a squash-merged run in red when CI on the merge commit fails" do
    stub_outside(conclusion: "failure", jobs: FAILED_JOBS)
    @pull = merged_as("e" * 40)
    landed = land
    advance(3)
    expect(stage(landed)).to eq("red")
  end

  it "keeps a run in ci_running while its pull request is open", :aggregate_failures do
    @pull = { number: 12, state: "OPEN", mergeCommit: nil }
    landed = land
    advance(3)
    expect(stage(landed)).to eq("ci_running")
    expect(@ci_commits).to be_nil
  end

  it "parks a run whose pull request closed unmerged, raising no red flag", :aggregate_failures do
    @pull = { number: 12, state: "CLOSED", mergeCommit: nil }
    landed = land
    advance(3)
    expect(stage(landed)).to eq("needs_human")
    expect(File.exist?(flag_file)).to be(false)
  end

  # Lands two runs while the first one's pull request is open, then merges it and advances.
  def land_two_behind_an_open_pull_request
    @pull = { number: 12, state: "OPEN", mergeCommit: nil }
    first = land
    advance(3)
    second = land(file: "second.rb")
    advance(2)
    @pull = merged_as("d" * 40)
    advance(3)
    [first, second]
  end

  it "boards the waiting run once the run ahead of it is green" do
    expect(land_two_behind_an_open_pull_request.map { |landed| stage(landed) }).to eq(%w[green green])
  end

  # An open train pull request whose checks are the given (name, status, conclusion) rows.
  def open_pull_with(*checks)
    rollup = checks.map { |name, status, conclusion| { name: name, status: status, conclusion: conclusion } }
    { number: 12, state: "OPEN", mergeCommit: nil, statusCheckRollup: rollup }
  end

  # Pushes one run behind an open pull request with these checks, then lands a second and advances.
  def land_behind_train_with(*checks)
    @pull = open_pull_with(*checks)
    first = land
    advance(3)
    second = land(file: "second.rb")
    advance(2)
    [first, second]
  end

  it "boards a verified landing behind a train whose checks failed", :aggregate_failures do
    _first, second = land_behind_train_with(["rspec 8/12", "COMPLETED", "FAILURE"], ["lint", "COMPLETED", "SUCCESS"])
    expect(@boardings.size).to eq(2)
    expect(stage(second)).to eq("ci_running")
  end

  it "waits on a train whose checks are still running, naming the counts", :aggregate_failures do
    first, second = land_behind_train_with(["rspec 8/12", "IN_PROGRESS", ""], ["lint", "COMPLETED", "SUCCESS"])
    expect(stage(second)).to eq("verified")
    expect(report("IntegrationAdvanced")).to include("waiting: #{first[0, 10]} is ci_running (1 of 2 checks)")
  end

  it "starts a run in landed when a branch lands on main" do
    landed = land
    expect(stage(landed)).to eq("landed")
  end

  # Lands one commit ahead of origin and advances it once, then once more.
  def board_and_advance_again
    landed = land
    advance
    after_one = [stage(landed), @boardings.size, report("IntegrationAdvanced")]
    advance
    after_one + [@boardings.size]
  end

  it "boards a verified landing in the advance that verified it, and never boards it again", :aggregate_failures do
    stage_after_one, boarded_once, line, boarded_after_two = board_and_advance_again
    expect([stage_after_one, boarded_once, boarded_after_two]).to eq(["pushed", 1, 1])
    expect(line).to include("-> Verify: now verified", "-> Board: now pushed; boarded ")
  end

  it "never boards a landing whose verification failed", :aggregate_failures do
    stub_outside(gate: [false, "[gate quick] red: rubocop"])
    land
    advance(2)
    expect(@boardings).to be_nil
    expect(report("IntegrationAdvanced")).to include("-> Verify: now needs_human; needs_human: ")
  end

  it "walks a run from landed to green" do
    landed = land
    advance(3)
    expect(stages_walked(landed)).to eq(%w[verifying verified boarding pushed ci_running green])
  end

  it "boards through the train's own copy with a fixed command line", :aggregate_failures do
    advance(2) if land
    expect(@boardings.first).to include("SendTrain.board!", "--confirm", "branch=main", "remote=origin")
    expect(@boardings.flatten.grep(/--force|--no-verify|HECKS_OWNER_PUSH/)).to be_empty
  end

  it "parks a run whose verification fails in needs_human, naming the failing check", :aggregate_failures do
    stub_outside(gate: [false, "[gate quick] red: rubocop"])
    landed = land
    advance(2)
    expect(stage(landed)).to eq("needs_human")
    expect(refusal("MainVerificationFailed")).to include("quick gate", "rubocop")
  end

  # A quick gate that is red for its first `times` runs and green after, counting every run.
  def red_gate(times)
    @gate_runs = 0
    Hecks::Adapters::MainVerification.runner = lambda do |argv, chdir:|
      next [true, "ok in #{chdir}"] unless argv.include?("gate_run.gate!")

      @gate_runs += 1
      @gate_runs <= times ? [false, "[gate quick] red: rubocop, try #{@gate_runs}"] : [true, "green"]
    end
  end

  # The names of the events that carry `landed`: the log is shared by every example of the file.
  def event_names(landed)
    @hecks.registry.event_log.select { |event| Hecks::Runtime::Value.materialize(event.payload).dig(:landed, :value) == landed }
          .map(&:name)
  end

  # Lands a run behind a gate red for its first `red` runs, advances it `times` and answers it.
  def land_behind_red_gate(red, times)
    red_gate(red)
    landed = land
    advance(times)
    landed
  end

  it "holds a run whose first verification fails for one more, parking nothing", :aggregate_failures do
    landed = land_behind_red_gate(1, 1)
    expect(stage(landed)).to eq("retrying")
    expect(event_names(landed)).to include("MainVerificationFailedOnce")
    expect(event_names(landed)).not_to include("MainVerificationFailed")
  end

  it "verifies and boards a run on the next advance when its retry passes", :aggregate_failures do
    landed = land_behind_red_gate(1, 2)
    expect(stages_walked(landed)).to eq(%w[verifying retrying reverifying verified boarding pushed])
    expect(@gate_runs).to eq(2)
  end

  it "parks a run whose retry fails too, keeping both refusals", :aggregate_failures do
    landed = land_behind_red_gate(2, 2)
    expect(stage(landed)).to eq("needs_human")
    expect(refusal("MainVerificationFailedOnce")).to include("quick gate", "try 1")
    expect(refusal("MainVerificationFailed")).to include("quick gate", "try 2")
  end

  it "never retries a run's verification twice", :aggregate_failures do
    landed = land_behind_red_gate(5, 4)
    expect(@gate_runs).to eq(2)
    expect(stages_walked(landed)).to eq(%w[verifying retrying reverifying needs_human])
  end

  it "ends a run whose CI fails in red, naming the failed jobs", :aggregate_failures do
    stub_outside(conclusion: "failure", jobs: FAILED_JOBS)
    landed = land
    advance(3)
    expect(stage(landed)).to eq("red")
    expect(report("CiFailed")).to end_with("failed jobs: rspec 1/4")
  end

  def flag_file = File.join(repo, ".git", "hecks-red-flag.json")

  it "raises the red flag when a run's CI fails, carrying the commit and failed jobs", :aggregate_failures do
    stub_outside(conclusion: "failure", jobs: FAILED_JOBS)
    landed = land
    advance(3)
    expect(File.read(flag_file)).to include(landed, "rspec 1/4")
    expect(@hecks.registry.event_log.map(&:name)).to include("RedFlagRaised")
  end

  it "stands no flag when CI passes" do
    land
    advance(3)

    expect(File.exist?(flag_file)).to be(false)
  end

  it "lowers a standing flag when a later run's CI passes", :aggregate_failures do
    land
    File.write(flag_file, JSON.generate(id: "flag-old", commit: "old", runs: [], checkins: []))
    advance(3)

    expect(File.exist?(flag_file)).to be(false)
    expect(@hecks.registry.event_log.map(&:name)).to include("RedFlagCleared")
  end

  it "refuses to board a range carrying an agent's trailer, by name", :aggregate_failures do
    landed = land(message: "feature\n\nCo-Authored-By: Claude <noreply@anthropic.com>")
    advance
    expect(stage(landed)).to eq("needs_human")
    expect(refusal("MainPushRefused")).to include("Co-Authored-By: Claude")
    expect(report("IntegrationAdvanced")).to include("-> Board: now needs_human; needs_human: ")
  end

  it "refuses to board a version change, by name", :aggregate_failures do
    landed = land(file: "lib/hecks/version.rb")
    advance(2)
    expect(stage(landed)).to eq("needs_human")
    expect(refusal("MainPushRefused")).to include("lib/hecks/version.rb")
  end

  it "does nothing on a second advance once a run is green", :aggregate_failures do
    landed = land
    advance(3)
    expect { advance }.not_to(change { stages_walked(landed) })
    expect(stage(landed)).to eq("green")
  end

  it "holds a verified run back without --confirm, however often it is advanced", :aggregate_failures do
    landed = land
    3.times { launch("Integration.advance!", "--wait") }
    expect(stage(landed)).to eq("verified")
    expect(@boardings).to be_nil
    expect(report("IntegrationAdvanced")).to include("waiting: advance with --confirm to push main")
  end

  it "marks an older landed run superseded when main has moved past it" do
    older = land
    land(file: "second.rb")
    advance
    expect(stage(older)).to eq("superseded")
  end

  # A defect in an adapter: an ask refuses what the outside world says, but raises this past itself.
  def defect(*, **) = raise(NoMethodError, "undefined method 'conclusion' for nil")

  # Pushes one run, lands a second behind it, and gives reading GitHub a defect.
  def push_one_and_land_another_while_github_is_broken
    pushed = land
    advance
    later = land(file: "second.rb")
    Hecks::Adapters::CiRuns.runner = method(:defect)
    advance
    [pushed, later]
  end

  it "advances the next run when one run's step raises", :aggregate_failures do
    pushed, later = push_one_and_land_another_while_github_is_broken
    expect(stage(pushed)).to eq("ci_running")
    expect(stage(later)).to eq("verified")
    expect(report("IntegrationAdvanced")).to include("Observe raised NoMethodError", "waiting: #{pushed[0, 10]} is ci_running")
  end

  it "parks a run whose verification raises, with the exception's text", :aggregate_failures do
    Hecks::Adapters::MainVerification.runner = method(:defect)
    landed = land
    advance
    expect(stage(landed)).to eq("needs_human")
    expect(refusal("MainVerificationFailed")).to include("Verify raised NoMethodError", "'conclusion'")
  end

  it "keeps every step within the reaction depth bound", :aggregate_failures do
    advance(3) if land
    expect(@depths.max).to be < Hecks::Runtime::Dispatcher::MAX_REACTION_DEPTH
    expect(@hecks.registry.reaction_log.map { |entry| entry[:reason].to_s }.grep(/reaction depth/)).to be_empty
  end
end
