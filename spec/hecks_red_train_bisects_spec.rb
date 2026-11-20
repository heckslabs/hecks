require "spec_helper"
require_relative "support/red_train_repository"

# A red train resolves itself: a train pull request whose CI names a failing example is searched
# for the landing that turned it red, over what the train holds beyond origin/main, and the
# bluebook's rules revert that landing and reopen its work item, with no coder started. The
# repository is a throwaway one; GitHub's reruns and the probes of the search are stand-ins.
RSpec.describe "a red train bisecting to its culprit" do
  include RedTrainRepository

  let(:dir) { File.realpath(Dir.mktmpdir("hecks-red-train")) }
  let(:repo) { File.join(dir, "main") }
  let(:reruns) { [] }

  before(:all) { @hecks = boot_hecks_in_memory }

  before do
    open_repository
    @logged = @hecks.registry.event_log.size
    Hecks::Adapters::CiRuns.runner = ->(argv, chdir:) { [true, (reruns << argv.join(" ")) && chdir] }
    Hecks::Adapters::MainVerification.log_directory = File.join(dir, "verification-logs")
    Hecks::Adapters::MainIntegration::CodeWatch.fingerprint = instance_double(
      Hecks::Adapters::Driving::Resident::Fingerprint, current: 1
    )
  end

  after do
    Hecks::Adapters::CiRuns.runner = nil
    Hecks::Adapters::MainVerification.runner = nil
    Hecks::Adapters::MainVerification.specs = nil
    Hecks::Adapters::MainVerification.log_directory = nil
    Hecks::Adapters::MainIntegration::CodeWatch.fingerprint = nil
    FileUtils.remove_entry(dir)
  end

  # The facts one failed attempt of a train pull request's CI is recorded with.
  def attempt_facts(landed, facts)
    key = SecureRandom.hex(6)
    { key: key, landed: landed, pr: "7", ci_run: "77", attempt: 2, specs: "spec/bad_spec.rb",
      work: "red-train-#{key}", title: "Red train PR 7", cause: "spec", failure: "PR 7 CI failed", failed_jobs: 1, job: "11",
      examples: "spec/bad_spec.rb:3", related: "yes", checkout: repo, step: "rspec/Run specs" }.merge(facts)
  end

  def fail_ci(landed = head, **facts)
    Hecks::Runtime::Dispatcher.new(@hecks.registry).dispatch_flat("Hecks::TrainPr.Record", attempt_facts(landed, facts))
  end

  def event_names = @hecks.registry.event_log.drop(@logged).map(&:name)

  def payload(name)
    event = @hecks.registry.event_log.drop(@logged).reverse.find { |logged| logged.name == name }
    Hecks::Runtime::Value.materialize(event.payload)
  end

  def red_train
    stand_in
    fail_ci(train_of_five)
  end

  it "reverts the one bad landing among five as one commit", :aggregate_failures do
    red_train
    expect(reverts).to eq(["Revert \"Merge branch 'three'\""])
    expect(File.exist?(File.join(repo, "bad.rb"))).to be(false)
  end

  it "starts no coder: the attempt is searched, not exhausted", :aggregate_failures do
    red_train
    expect(event_names).to include("TrainPrSearched", "EpisodeReverting", "LandingReverted")
    expect(event_names).not_to include("TrainPrExhausted", "WorkPlanned")
  end

  it "reopens the culprit's work item with the example, the search's log and how to land again", :aggregate_failures do
    red_train
    reverting = payload("EpisodeReverting")
    expect(reverting.dig(:work, :value)).to eq("three")
    expect(reverting.dig(:finding, :value)).to include("culprit #{@bad}", "breaks the build", "search: ", "To land it again")
  end

  it "lowers the flag once the revert of a landing that never left local main is verified" do
    red_train
    expect(event_names).to include("RedFlagRaised", "RedFlagCleared", "EpisodeReverted")
  end

  it "marks an example that is red at origin/main too as there before, and files nothing", :aggregate_failures do
    stand_in(everywhere: true)
    fail_ci(train_of_five)
    expect(event_names).to include("EpisodeAcquitted")
    expect(event_names).not_to include("EpisodeReverting", "TrainPrExhausted", "WorkPlanned")
  end

  it "gives the train to a coder, with no flag raised, when no landing turns the example red", :aggregate_failures do
    stand_in(green: true)
    fail_ci(train_of_five)
    expect(event_names).to include("TrainPrExhausted", "WorkPlanned")
    expect(event_names).not_to include("RedFlagRaised", "EpisodeUnfound")
  end

  # The train that boards after the first revert is red on another example, which another landing
  # broke: its range holds the first revert.
  def second_red_train
    stand_in
    land("worse")
    fail_ci(train_of_five)
    fail_ci(examples: "spec/worse_spec.rb:3")
  end

  it "reverts a second culprit of the range in an episode of its own", :aggregate_failures do
    second_red_train
    expect(reverts).to eq(["Revert \"Merge branch 'worse'\"", "Revert \"Merge branch 'three'\""])
    expect(event_names.count("EpisodeReverting")).to eq(2)
  end

  it "parks, and reverts nothing twice, when the culprit's own revert already stands", :aggregate_failures do
    red_train
    fail_ci
    expect(event_names).to include("EpisodeParked")
    expect(reverts.size).to eq(1)
  end

  # A commit made on main itself, between two landings, adds the bad file.
  def broken_between_landings
    stand_in
    land("one")
    File.write(File.join(repo, "bad.rb"), "bad")
    commit("a commit on main")
    fail_ci(land("two"))
  end

  it "blames no landing whose first parent is red too", :aggregate_failures do
    broken_between_landings
    expect(event_names).not_to include("EpisodeReverting")
    expect(payload("TrainPrExhausted").dig(:detail, :value)).to include("is red and so is its parent")
  end

  it "searches each failing example in turn until one names a landing" do
    stand_in
    fail_ci(train_of_five, examples: "spec/worse_spec.rb:3,spec/bad_spec.rb:3")
    expect(reverts).to eq(["Revert \"Merge branch 'three'\""])
  end

  # Which of the three ends one failed attempt comes to: rerun, searched or exhausted.
  def ending(**facts)
    stand_in(everywhere: true)
    @logged = @hecks.registry.event_log.size
    fail_ci(head, **facts)
    event_names.grep(/\ATrainPr(Rerun|Searched|Exhausted)\z/)
  end

  it "reruns a setup failure once and exhausts it after", :aggregate_failures do
    expect(ending(cause: "setup", attempt: 1, examples: "")).to eq(["TrainPrRerun"])
    expect(ending(cause: "setup", attempt: 2, examples: "")).to eq(["TrainPrExhausted"])
  end

  it "reruns the one unrelated failed job of a first attempt, with or without an example", :aggregate_failures do
    expect(ending(attempt: 1, related: "no")).to eq(["TrainPrRerun"])
    expect(ending(attempt: 1, related: "no", examples: "")).to eq(["TrainPrRerun"])
  end

  it "searches every other spec failure that names an example", :aggregate_failures do
    expect(ending(attempt: 1)).to eq(["TrainPrSearched"])
    expect(ending(attempt: 1, related: "no", failed_jobs: 2)).to eq(["TrainPrSearched"])
    expect(ending(attempt: 3, related: "no")).to eq(["TrainPrSearched"])
  end

  it "exhausts a spec failure that names no example" do
    expect(ending(attempt: 2, examples: "")).to eq(["TrainPrExhausted"])
  end
end
