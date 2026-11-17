require "spec_helper"
require "fileutils"
require "json"
require "open3"
require "tmpdir"

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
    git("commit", "--allow-empty", "-m", "start")
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

  it "reverts nothing when the spec is red at the last verified commit too", :aggregate_failures do
    stub_outside(everywhere: true)
    verify(three_landings.last)
    expect(event_names).to include("EpisodeAcquitted")
    expect(event_names).not_to include("EpisodeReverting")
    expect(subjects.first).to eq("Merge branch 'three'")
  end
end
