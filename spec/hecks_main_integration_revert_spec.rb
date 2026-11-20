require "spec_helper"
require "fileutils"
require "json"
require "open3"
require "tmpdir"
require_relative "support/hecks_launcher_stub"

# A red main reverts its one bad merge by policy: a verification that fails twice is searched for
# its first bad merge, the bluebook decides (revert, park or acquit), the red flag holds landings
# while the revert is made and verified, and a spec that is red at the last verified commit too
# reverts nothing. The repository is a throwaway one; the checks a verification runs are stubbed.
RSpec.describe "a red main reverting its one bad merge" do
  let(:dir) { File.realpath(Dir.mktmpdir("hecks-red-main")) }
  let(:repo) { File.join(dir, "main") }
  let(:flag_file) { File.join(repo, ".git", "hecks-red-flag.json") }

  before(:all) do
    @hecks = boot_hecks_in_memory
  end

  before do
    open_repository
    @logged = @hecks.registry.event_log.size
    Hecks::Adapters::GitShallowCheck::Switch.new(File.join(repo, ".git")).set("off")
    Hecks::Adapters::MainIntegration::Bisecting.searches.clear
    Hecks::Adapters::MainVerification.log_directory = File.join(dir, "verification-logs")
    Hecks::Adapters::MainIntegration::CodeWatch.fingerprint = instance_double(
      Hecks::Adapters::Driving::Resident::Fingerprint, current: 1
    )
  end

  after do
    Hecks::Adapters::MainVerification.runner = nil
    Hecks::Adapters::MainVerification.impacted = nil
    Hecks::Adapters::MainVerification.specs = nil
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
    git("config", "user.name", "t")
    git("config", "user.email", "t@t")
    HecksLauncherStub.place(repo)
    git("add", ".")
    git("commit", "-q", "-m", "start")
    git("push", "-q", "origin", "main")
  end

  # Merges a branch holding one file into local main, as a landing does, and answers main's commit.
  def merge_branch(name, file)
    git("checkout", "-q", "-b", name)
    File.write(File.join(repo, file), SecureRandom.hex)
    git("add", ".")
    git("commit", "-q", "-m", name)
    git("checkout", "-q", "main")
    git("merge", "-q", "--no-ff", "-m", "Merge branch '#{name}'", name)
    git("rev-parse", "main").strip
  end

  # The last verified commit, then three landings, the second of which adds the bad file.
  def three_landings
    base = git("rev-parse", "main").strip
    Hecks::Adapters::MainIntegration::LastVerified.write(File.join(repo, ".git"), base)
    @base = base
    [merge_branch("one", "one.rb"), (@bad = merge_branch("two", "bad.rb")), merge_branch("three", "three.rb")]
  end

  # The gate is red in a copy that holds the bad file (or always, with `always`); the impacted
  # specs are red for the merge that adds it and every merge after it, and, with `everywhere`,
  # at the last verified commit too (a spec that fails on this machine only).
  def stub_outside(revert_red: false, everywhere: false)
    Hecks::Adapters::MainVerification.runner = lambda do |argv, chdir:|
      red = File.exist?(File.join(chdir, "bad.rb")) || (revert_red && reverted_copy?(chdir))
      argv.include?("gate_run.gate!") && red ? [false, "[gate quick] red: rspec spec/bad_spec.rb"] : [true, "ok"]
    end
    Hecks::Adapters::MainVerification.impacted = impacted_run(everywhere)
    stub_probes(everywhere: everywhere)
  end

  # The probe of the search runs the failing spec file in a copy: red where the bad file is (or
  # everywhere, or never with `green`), whatever the merge's own paths touch.
  def stub_probes(everywhere: false, green: false)
    Hecks::Adapters::MainVerification.specs = lambda do |directory, _files|
      red = !green && (everywhere || File.exist?(File.join(directory, "bad.rb")))
      raise Hecks::Adapters::ConsoleCapture::Failure, "failing spec: spec/bad_spec.rb # bad example" if red
    end
  end

  def reverted_copy?(directory) = git("log", "-1", "--format=%s", chdir: directory).start_with?("Revert")

  def impacted_run(everywhere)
    lambda do |changed, since|
      if red_spec?(changed, since, everywhere)
        raise Hecks::Adapters::ConsoleCapture::Failure, "rspec spec/bad_spec.rb\n  1) bad example"
      end

      Hecks::Adapters::GitShallowCheck::ImpactedRun::Outcome.new([], [], 0, 0)
    end
  end

  # Whether the bad spec is red in a copy at `since`: the merge that adds it is probed against its
  # parent, and a later merge holds it.
  def red_spec?(changed, since, everywhere)
    adds = changed.include?("bad.rb") && (everywhere || since != @base)
    adds || system("git", "merge-base", "--is-ancestor", @bad, since, chdir: repo)
  end

  def refusal
    failed = @hecks.registry.event_log.reverse.find { |event| event.name == "MainVerificationFailed" }
    Hecks::Runtime::Value.materialize(failed.payload).dig(:refusal, :value).to_s
  end

  # The revert's own verification is red too: a second red in the same episode.
  def verify_twice
    stub_outside(revert_red: true)
    verify(three_landings.last)
  end

  def reverts = subjects.count { |subject| subject.start_with?("Revert") }

  def verify(commit)
    Hecks::Adapters::Driving::CliRunner.call(
      runtime: @hecks, program: "hecks",
      argv: ["Integration.verify!", "run=#{commit}", "landed.value=#{commit}", "checkout.value=#{repo}",
             "retried.value=true", "--wait"]
    )
  end

  # The events this example caused: the log is shared by every example of the file.
  def event_names = @hecks.registry.event_log.drop(@logged).map(&:name)

  def refused_reason(name)
    event = @hecks.registry.event_log.reverse.find { |logged| logged.name == name }
    Hecks::Runtime::Value.materialize(event.payload).dig(:refusal, :value).to_s
  end

  def subjects = git("log", "--format=%s", "-8").lines.map(&:strip)

  def landing_refused? = !landing_error.nil?

  def landing_error
    Hecks::Adapters::RedFlagGuard.new(File.join(repo, ".git")).landing!("feature")
    nil
  rescue Hecks::Adapters::ConsoleCapture::Failure => e
    e.message
  end

  def fail_the_last_landing
    stub_outside
    verify(three_landings.last)
  end

  it "reverts the one bad merge among several, naming its spec in the refusal", :aggregate_failures do
    fail_the_last_landing
    expect(subjects.first).to eq("Revert \"Merge branch 'two'\"")
    expect(File.exist?(File.join(repo, "bad.rb"))).to be(false)
    expect(event_names).to include("MainVerificationFailed", "EpisodeReverting", "LandingReverted")
  end

  it "holds landings by name while the revert is made, then releases them once it verifies", :aggregate_failures do
    fail_the_last_landing
    expect(event_names).to include("RedFlagRaised", "RedFlagCleared")
    expect(landing_refused?).to be(false)
  end

  it "records the revert on the episode and ends it reverted once the revert verifies" do
    fail_the_last_landing
    expect(event_names).to include("EpisodeRevertMade", "EpisodeReverted")
  end

  it "names the first bad merge and its failing spec in the verification's refusal" do
    fail_the_last_landing
    expect(refusal).to include("first bad merge #{@bad[0, 10]} Merge branch 'two'", "spec spec/bad_spec.rb")
  end

  it "parks a second red in the same episode instead of reverting again", :aggregate_failures do
    verify_twice
    expect(event_names).to include("EpisodeParked")
    expect(reverts).to eq(1)
    expect(landing_refused?).to be(true)
  end

  # The first of three landings adds the bad file; the two after it touch other files only.
  def first_of_three_is_bad
    base = git("rev-parse", "main").strip
    Hecks::Adapters::MainIntegration::LastVerified.write(File.join(repo, ".git"), base)
    @bad = merge_branch("one", "bad.rb")
    merge_branch("two", "two.rb")
    merge_branch("three", "three.rb")
  end

  it "reverts the first merge when the later ones do not touch the failing spec", :aggregate_failures do
    stub_outside
    verify(first_of_three_is_bad)
    expect(subjects.first).to eq("Revert \"Merge branch 'one'\"")
    expect(event_names).to include("EpisodeReverting")
  end

  def verify_with_no_merge_red
    stub_outside
    stub_probes(green: true)
    verify(three_landings.last)
  end

  it "raises the flag and tells the owner when no single merge is red", :aggregate_failures do
    verify_with_no_merge_red
    expect(event_names).to include("EpisodeUnfound", "RedFlagRaised")
    expect(landing_refused?).to be(true)
  end

  it "reverts and acquits nothing when no single merge is red", :aggregate_failures do
    verify_with_no_merge_red
    expect(event_names).not_to include("EpisodeReverting", "EpisodeAcquitted")
    expect(reverts).to eq(0)
  end

  it "reverts nothing when the spec is red at the last verified commit too", :aggregate_failures do
    stub_outside(everywhere: true)
    verify(three_landings.last)
    expect(event_names).to include("EpisodeAcquitted")
    expect(event_names).not_to include("EpisodeReverting")
    expect(subjects.first).to eq("Merge branch 'three'")
  end

  def episode_payload(name)
    event = @hecks.registry.event_log.drop(@logged).reverse.find { |logged| logged.name == name }
    Hecks::Runtime::Value.materialize(event.payload)
  end

  def boarding_error(commit)
    Hecks::Adapters::RedFlagGuard.new(File.join(repo, ".git")).boarding!(commit)
    nil
  rescue Hecks::Adapters::ConsoleCapture::Failure => e
    e.message
  end

  # The bad merge is reverted by hand before the verification: the range already holds a revert.
  def hand_revert_then_verify
    stub_outside(revert_red: true)
    three_landings
    git("revert", "-m", "1", "--no-edit", @bad)
    verify(git("rev-parse", "main").strip)
  end

  # The bad merge reaches origin/main before the verification; the landing after it stays local.
  def verify_with_the_culprit_on_origin
    stub_outside
    base = git("rev-parse", "main").strip
    Hecks::Adapters::MainIntegration::LastVerified.write(File.join(repo, ".git"), base)
    @base = base
    merge_branch("one", "one.rb")
    @bad = merge_branch("two", "bad.rb")
    git("push", "-q", "origin", "main")
    verify(merge_branch("three", "three.rb"))
  end

  it "reopens the culprit's work item with its spec and commit, at the top of the plan", :aggregate_failures do
    fail_the_last_landing
    reverting = episode_payload("EpisodeReverting")
    expect(reverting.dig(:work, :value)).to eq("two")
    expect(reverting.dig(:finding, :value)).to include("culprit #{@bad}", "spec spec/bad_spec.rb")
  end

  def run_cli(*argv)
    Hecks::Adapters::Driving::CliRunner.call(runtime: @hecks, program: "hecks", argv: [*argv, "--wait"])
  end

  def finished_work_item(key)
    run_cli("Work.plan!", "work.value=#{key}", "title.value=planned", "detail.value=d")
    run_cli("Work.finish!", "to=#{key}", "no_change.value=a verify")
  end

  it "plans the culprit's finished work item again, as now", :aggregate_failures do
    finished_work_item("two")
    fail_the_last_landing
    expect(event_names).to include("WorkReopened", "WorkPrioritized")
  end

  it "keeps the step or retry suffix out of the work item the episode names" do
    expect(Hecks::Adapters::MainIntegration::Searching::WORK_SUFFIX.match?("a-b-step2")).to be(true)
  end

  it "raises the flag when a hand revert parks the episode, so landings stop", :aggregate_failures do
    hand_revert_then_verify
    expect(event_names).to include("EpisodeParked", "RedFlagRaised")
    expect(landing_refused?).to be(true)
  end

  it "reverts a culprit that reached origin/main locally and leaves the flag up", :aggregate_failures do
    verify_with_the_culprit_on_origin
    expect(subjects.first).to eq("Revert \"Merge branch 'two'\"")
    expect(landing_refused?).to be(true)
  end

  it "admits that revert for boarding and no other commit", :aggregate_failures do
    verify_with_the_culprit_on_origin
    expect(event_names).to include("RedFlagRevertAdmitted")
    expect(boarding_error(git("rev-parse", "main").strip)).to be_nil
    expect(boarding_error(@bad)).to include("only the tip of a red-* Work item's fix is boarded")
  end

  it "lets a red-* fix that lands after the admitted revert board in its place", :aggregate_failures do
    verify_with_the_culprit_on_origin
    Hecks::Adapters::RedFlagGuard.new(File.join(repo, ".git")).landed("red-two", @bad)
    expect(boarding_error(@bad)).to be_nil
  end

  it "tells the owner through the orchestrator when a hand revert parks the episode" do
    hand_revert_then_verify
    expect(event_names).to include("CoordinatorWoken")
  end

  # A tracked file is changed in the checkout before the verification, so the revert is refused.
  def verify_over_a_dirty_checkout
    stub_outside
    landed = three_landings.last
    File.write(File.join(repo, "one.rb"), "changed")
    verify(landed)
  end

  it "tells the owner through the orchestrator when the revert is refused, and holds landings", :aggregate_failures do
    verify_over_a_dirty_checkout
    expect(event_names).to include("RevertRefused", "CoordinatorWoken")
    expect(landing_refused?).to be(true)
  end
end
