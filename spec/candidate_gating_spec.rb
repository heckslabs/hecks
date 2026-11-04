require "spec_helper"
require "fileutils"
require "json"
require "open3"
require "tmpdir"
require "hecks/hecks/adapters/candidate_gating"

# The adapter behind the Candidate port (ADR 0181): observe, promote, reject, switch and status,
# each against a scratch bare remote and a clone whose git directory holds the candidate's record.
# GitHub is a fake whose run list and run view answer what each example sets. No Tickets are booted
# here, so a rejection files nothing; the cause grouping is read on its own.
RSpec.describe Hecks::Adapters::CandidateGating do
  let(:scratch) { Dir.mktmpdir("hecks-candidate-gating") }
  let(:work) { File.join(scratch, "work") }
  let(:runs) { [] }
  let(:gating) { described_class.new(checkout: work, runner: ->(argv, **) { github(argv) }) }
  let(:identity) do
    { "GIT_AUTHOR_NAME" => "A", "GIT_AUTHOR_EMAIL" => "a@example.test",
      "GIT_COMMITTER_NAME" => "A", "GIT_COMMITTER_EMAIL" => "a@example.test" }
  end

  def git(*args, dir: work)
    out, err, status = Open3.capture3(identity, "git", *args, chdir: dir)
    raise "git #{args.join(" ")} failed: #{err}" unless status.success?

    out.strip
  end

  def commit(name)
    File.write(File.join(work, name), name)
    git("add", name)
    git("commit", "-q", "-m", name)
  end

  # A fake GitHub: the run list answers `runs`; a run view answers two failed jobs and a green one.
  def github(argv)
    return [true, JSON.generate(runs)] if argv[1..2] == %w[run list]

    jobs = [{ "name" => "rspec_impl (3)", "conclusion" => "failure" }, { "name" => "lint", "conclusion" => "success" },
            { "name" => "rspec_impl (5)", "conclusion" => "failure" }]
    [true, JSON.generate("jobs" => jobs)]
  end

  def marker = Hecks::Adapters::CandidateMarker.new(File.join(work, ".git"))

  def remote(ref) = git("ls-remote", "origin", ref).split.first

  # Queues local main's tip as the candidate the way the train does: pushed to the ref, recorded.
  def queue(name = "feature")
    commit(name)
    git("push", "-q", "origin", "+main:refs/heads/candidate")
    marker.queue!(sha: git("rev-parse", "main"), base: git("rev-parse", "origin/main"), commits: 1)
    git("rev-parse", "main")
  end

  def completed(conclusion) = runs << { "databaseId" => 7, "status" => "completed", "conclusion" => conclusion }

  def outcome(answer) = answer.dig(:outcome, :value)

  before do
    git("init", "-q", "--bare", "-b", "main", "origin.git", dir: scratch)
    git("clone", "-q", "origin.git", work, dir: scratch)
    git("checkout", "-q", "-b", "main")
    commit("first")
    git("push", "-q", "origin", "main")
  end

  after { FileUtils.remove_entry(scratch) }

  describe "observing" do
    it "is idle with no candidate recorded" do
      expect(outcome(gating.look)).to eq("idle")
    end

    it "is running while the candidate has no run yet" do
      queue

      expect(gating.look).to include(outcome: { value: "running" }, report: { value: a_string_including("no CI run yet") })
    end

    it "records a green candidate as green and says the workflow promotes it", :aggregate_failures do
      queue
      completed("success")

      expect(gating.look.dig(:report, :value)).to include("is green", "Candidate.promote!")
      expect(marker.read).to include("state" => "green", "ci_run" => "7")
    end

    it "records a red candidate with the failed jobs", :aggregate_failures do
      queue
      completed("failure")

      expect(gating.look).to include(outcome: { value: "red" }, jobs: { value: "rspec_impl (3), rspec_impl (5)" })
      expect(marker.read).to include("state" => "red")
    end

    it "sees a candidate the remote's main holds as promoted", :aggregate_failures do
      sha = queue
      git("push", "-q", "origin", "#{sha}:refs/heads/main")

      expect(gating.look).to include(outcome: { value: "promoted" }, sha: { value: sha })
      expect(marker.read).to include("state" => "promoted")
    end
  end

  describe "promoting from here" do
    it "fast-forwards the remote's main onto a green candidate", :aggregate_failures do
      sha = queue
      completed("success")

      expect(outcome(gating.forward)).to eq("promoted")
      expect(remote("refs/heads/main")).to eq(sha)
    end

    it "refuses a candidate that is not green" do
      queue
      completed("failure")

      expect { gating.forward }.to raise_error(Hecks::Adapters::ConsoleCapture::Failure, /is not green: CI run 7 failed/)
    end

    it "refuses with no candidate" do
      expect { gating.forward }.to raise_error(Hecks::Adapters::ConsoleCapture::Failure, /no candidate is recorded/)
    end
  end

  describe "rejecting" do
    it "keeps the commits on rejected/<sha> and resets local main to the remote's", :aggregate_failures do
      sha = queue
      completed("failure")
      gating.clear

      expect(git("rev-parse", "rejected/#{sha[0, 12]}")).to eq(sha)
      expect(git("rev-parse", "main")).to eq(git("rev-parse", "origin/main"))
    end

    it "names the authors and files no Work item without Tickets", :aggregate_failures do
      queue
      completed("failure")
      answer = gating.clear

      expect(answer).to include(outcome: { value: "rejected" }, authors: { value: "A" }, work_items: { value: "" })
      expect(marker.read).to include("state" => "rejected")
    end

    it "refuses a candidate that is not red" do
      queue
      completed("success")

      expect { gating.clear }.to raise_error(Hecks::Adapters::ConsoleCapture::Failure, /is not red: CI run 7 passed/)
    end

    it "refuses an unclean local main, moving nothing", :aggregate_failures do
      sha = queue
      completed("failure")
      File.write(File.join(work, "feature"), "edited")

      expect { gating.clear }.to raise_error(Hecks::Adapters::ConsoleCapture::Failure, /local main is not clean/)
      expect(git("rev-parse", "main")).to eq(sha)
    end

    it "refuses with no candidate" do
      expect { gating.clear }.to raise_error(Hecks::Adapters::ConsoleCapture::Failure, /no candidate is recorded/)
    end
  end

  describe "the switch" do
    it "turns the gate on in the repository's git configuration", :aggregate_failures do
      expect(outcome(gating.flip(setting: { value: "on" }))).to eq("switched")
      expect(git("config", "--get", Hecks::Adapters::CandidateGate::CONFIG)).to eq("true")
    end

    it "turns it off again" do
      gating.flip(setting: { value: "on" })
      gating.flip(setting: { value: "off" })

      expect(git("config", "--get", Hecks::Adapters::CandidateGate::CONFIG)).to eq("false")
    end

    it "is off by default, from the world" do
      expect(gating.status[:text]).to start_with("candidate gate off (the Hecks world)")
    end
  end

  describe Hecks::Adapters::CandidateGating::Causes do
    it "groups the shards of one job under one cause" do
      causes = described_class.new("rspec_impl (3), rspec_impl (5), checks_fuzz_1_of_3")

      expect(causes.grouped.keys).to eq(%w[rspec_impl checks_fuzz])
    end

    it "groups a job a lesson's signature matches under the lesson's kind" do
      lesson = { kind: "shallow-clone", signature: ["rspec_impl"], always: "no", area: [] }
      causes = described_class.new("rspec_impl (3), lint", lessons: [lesson])

      expect(causes.grouped.keys).to eq(%w[shallow-clone lint])
    end

    it "keys a cause as a red Work item" do
      expect(described_class.new("lint").key("lint")).to start_with("red-lint-")
    end
  end
end
