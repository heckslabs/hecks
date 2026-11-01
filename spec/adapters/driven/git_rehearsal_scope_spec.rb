require "spec_helper"
require "fileutils"
require "open3"
require "tmpdir"
require "hecks/hecks/adapters/git_rehearsal"

# A rehearsal's scope: `quick` runs only the gate's quick stage and is recorded and queued apart
# from `full`, which runs every stage. The stages are stubbed; the repository is a throwaway one.
RSpec.describe Hecks::Adapters::GitRehearsal, "#trial", :aggregate_failures, :io do
  IDENT = { "GIT_AUTHOR_NAME" => "A", "GIT_AUTHOR_EMAIL" => "a@example.test",
            "GIT_COMMITTER_NAME" => "A", "GIT_COMMITTER_EMAIL" => "a@example.test" }.freeze
  let(:scratch) { Dir.mktmpdir("hecks-git-rehearsal-scope") }
  let(:work) { File.join(scratch, "work") }
  let(:seen) { [] }

  def git(*args, dir: work)
    out, err, status = Open3.capture3(IDENT, "git", *args, chdir: dir)
    raise "git #{args.join(" ")} failed: #{err}" unless status.success?

    out.strip
  end

  def commit(name)
    File.write(File.join(work, name), name)
    git("add", name)
    git("commit", "-q", "-m", name)
  end

  def stage(name, passed: true) = Hecks::Adapters::GitRehearsal::Stages::Result.new(name, passed, "")

  def trial(**held) = described_class.new.trial(checkout: { value: work }, **held)

  def due = described_class.new.due(checkout: { value: work })[:text]

  def record_file(suffix = "") = File.join(work, ".git", "#{Hecks::Adapters::GitRehearsal::Record::FILE}#{suffix}")

  def failed_stage = stage("impacted specs", passed: false)

  def record_old_format
    head = git("rev-parse", "main")
    File.write(record_file, "#{head} red #{Time.now.to_i} quick\n")
    head
  end

  def run_both_then_move
    commit("second")
    trial(scope: { value: "quick" })
    trial
    git("rev-parse", "main")[0, 9].tap { commit("third") }
  end

  def stub_stages
    allow(Hecks::Adapters::GitRehearsal::Stages).to receive(:new) do |_dir, **options|
      instance_double(Hecks::Adapters::GitRehearsal::Stages).tap do |stages|
        allow(stages).to receive(:run) do
          seen << options[:scope]
          yield options[:scope]
        end
      end
    end
  end

  before do
    git("init", "-q", "--bare", "-b", "main", "origin.git", dir: scratch)
    git("clone", "-q", "origin.git", work, dir: scratch)
    git("checkout", "-q", "-b", "main")
    commit("first")
    git("push", "-q", "origin", "main")
    stub_stages { |scope| scope == "quick" ? [stage("quick")] : [stage("quick"), failed_stage] }
  end

  after { FileUtils.remove_entry(scratch) }

  it "defaults a hand rehearsal to full, with every stage" do
    answer = trial

    expect(seen).to eq(["full"])
    expect(answer[:report][:value]).to include("full rehearsal", "impacted specs: FAIL")
  end

  it "passes the quick scope to the stages" do
    answer = trial(scope: { value: "quick" })

    expect(seen).to eq(["quick"])
    expect(answer[:outcome]).to eq(value: "green")
  end

  it "refuses an unknown scope" do
    expect { trial(scope: { value: "half" }) }.to raise_error(Hecks::Adapters::ConsoleCapture::Failure, /quick, full, deep/)
  end

  it "runs the quick gate stage alone for the quick scope" do
    stages = Hecks::Adapters::GitRehearsal::Stages.new(work, scope: "quick")
    allow(stages).to receive(:gate).with("quick").and_return(stage("quick"))

    expect(stages.run.map(&:name)).to eq(["quick"])
  end

  describe "the record" do
    let(:recorder) { Hecks::Adapters::GitRehearsal::Record.new(Hecks::Adapters::Git.new, work) }

    it "keeps quick and full apart" do
      trial(scope: { value: "quick" })
      trial

      expect(File.read(record_file(".quick"))).to include(" green ")
      expect(File.read(record_file)).to include(" red ")
    end

    it "reads an old-format record as full" do
      head = record_old_format

      expect(recorder.last).to have_attributes(commit: head, verdict: "red", failed: "quick")
      expect(recorder.last("quick")).to be_nil
    end
  end

  describe "#due" do
    it "prints both lines" do
      short = run_both_then_move

      expect(due).to include("last quick: green on #{short} (main has moved since); " \
                             "last full: red (impacted specs) on #{short} (main has moved since)")
    end

    it "says a push needs a green full rehearsal while the last is red or stale" do
      run_both_then_move

      expect(due).to include("a push needs a green full rehearsal of the current main")
    end

    it "does not ask for one when the last full rehearsal is green on the current main" do
      commit("second")
      stub_stages { [stage("quick")] }
      trial

      expect(due).not_to include("a push needs")
    end
  end

  describe "the lines" do
    def land_during_first_quick
      stub_stages do
        next [stage("quick")] unless seen.size == 1

        commit("landed")
        @refused = refusal { trial(scope: { value: "quick" }) }
        [stage("quick")]
      end
    end

    def refusal
      yield
    rescue Hecks::Adapters::ConsoleCapture::Failure => e
      e.message
    end

    it "marks a land during a quick rehearsal pending, and runs quick once more for the latest main" do
      land_during_first_quick
      trial(scope: { value: "quick" })

      expect(@refused).to match(/\Apending: rehearse \h{9}/)
      expect(seen).to eq(%w[quick quick])
    end

    it "runs a quick rehearsal alongside a running full one" do
      inner = []
      stub_stages { |scope| [stage("quick")].tap { inner << trial(scope: { value: "quick" })[:outcome] if scope == "full" } }
      trial

      expect(inner).to eq([{ value: "green" }])
      expect(seen).to eq(%w[full quick])
    end
  end
end
