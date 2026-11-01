require "spec_helper"
require "fileutils"
require "open3"
require "tmpdir"
require "hecks/hecks/adapters/git_rehearsal"

# The Rehearsing port's adapter, against a disposable bare remote and a clone of it: the push-due
# query counts and ages the unpushed commits and reads the last rehearsal back, and the stages
# report pass or fail by name. The stages themselves are stubbed; no gate, spec or push runs.
RSpec.describe Hecks::Adapters::GitRehearsal, :io do
  DETAIL = "failing check: fuzzing; failing spec: ./spec/fuzzing/a_spec.rb:3".freeze
  IDENTITY = { "GIT_AUTHOR_NAME" => "A", "GIT_AUTHOR_EMAIL" => "a@example.test",
               "GIT_COMMITTER_NAME" => "A", "GIT_COMMITTER_EMAIL" => "a@example.test" }.freeze
  let(:scratch) { Dir.mktmpdir("hecks-git-rehearsal") }
  let(:work) { File.join(scratch, "work") }

  def git(*args, dir: work, env: IDENTITY)
    out, err, status = Open3.capture3(env, "git", *args, chdir: dir)
    raise "git #{args.join(" ")} failed: #{err}" unless status.success?

    out.strip
  end

  def commit(name, hours_ago: 0)
    File.write(File.join(work, name), name)
    git("add", name)
    stamp = (Time.now - (hours_ago * 3600)).to_i.to_s
    git("commit", "-q", "-m", name, env: IDENTITY.merge("GIT_COMMITTER_DATE" => stamp, "GIT_AUTHOR_DATE" => stamp))
  end

  def stage(name, passed, detail = "")
    Hecks::Adapters::GitRehearsal::Stages::Result.new(name, passed, detail)
  end

  before do
    git("init", "-q", "--bare", "-b", "main", "origin.git", dir: scratch)
    git("clone", "-q", "origin.git", work, dir: scratch)
    git("checkout", "-q", "-b", "main")
    commit("first")
    git("push", "-q", "origin", "main")
  end

  after { FileUtils.remove_entry(scratch) }

  def due = described_class.new.due(checkout: { value: work })[:text]

  def record(verdict, results)
    Hecks::Adapters::GitRehearsal::Record.new(Hecks::Adapters::Git.new, work).write(git("rev-parse", "main"), verdict, results)
  end

  describe "#due" do
    it "says no push is due when main is level with origin/main" do
      expect(due).to eq("push due: no; main is level with origin/main; last quick: none yet; last full: none yet")
    end

    it "counts the unpushed commits and ages the oldest in hours" do
      commit("second", hours_ago: 5)
      commit("third")

      expect(due).to include("push due: yes; 2 commit(s) ahead of origin/main; oldest unpushed 5.0 hours old")
    end

    it "reads back the last rehearsal" do
      commit("second")
      record("red", [stage("unguarded_push", false)])

      expect(due).to include("last full: red (unguarded_push) on #{git("rev-parse", "main")[0, 9]} (the current main)")
    end

    it "says when main has moved since the last rehearsal" do
      record("green", [stage("quick", true)])
      commit("second")

      expect(due).to include("main has moved since")
    end
  end

  describe "#trial" do
    let(:answer) { described_class.new.trial(checkout: { value: work }) }

    before do
      stages = instance_double(Hecks::Adapters::GitRehearsal::Stages, run: results)
      allow(Hecks::Adapters::GitRehearsal::Stages).to receive(:new).and_return(stages)
    end

    context "when every stage passes" do
      let(:results) { [stage("quick", true), stage("push specs", true, " (none exist yet)")] }

      it "answers green" do
        expect(answer[:outcome]).to eq(value: "green")
      end

      it "says pass for each stage" do
        expect(answer[:report][:value]).to include("quick: pass", "push specs: pass")
      end

      it "pushes nothing" do
        commit("second")
        answer

        expect(git("rev-parse", "origin/main")).not_to eq(git("rev-parse", "main"))
      end
    end

    context "when a stage fails" do
      let(:results) { [stage("quick", true), stage("unguarded_push", false, DETAIL)] }

      it "answers red" do
        expect(answer[:outcome]).to eq(value: "red")
      end

      it "names the failing stage, check and spec" do
        expect(answer[:report][:value]).to include("unguarded_push: FAIL #{DETAIL}")
      end

      it "records the verdict where the due query reads it" do
        answer

        expect(due).to include("last full: red (unguarded_push)")
      end
    end

    context "when the branch is not there" do
      let(:results) { [] }

      it "refuses" do
        expect { described_class.new.trial(checkout: { value: work }, branch: { value: "absent" }) }
          .to raise_error(Hecks::Adapters::ConsoleCapture::Failure)
      end
    end
  end

  describe "the record" do
    let(:recorder) { Hecks::Adapters::GitRehearsal::Record.new(Hecks::Adapters::Git.new, work) }
    let(:file) { File.join(work, ".git", Hecks::Adapters::GitRehearsal::Record::FILE) }

    def commit_after(name)
      commit(name)
      git("rev-parse", "main")
    end

    def write_for(commit, verdict = "green") = recorder.write(commit, verdict, [stage("quick", verdict == "green")])

    it "writes through a rename, leaving no temp file", :aggregate_failures do
      expect(write_for(git("rev-parse", "main"))).to eq("recorded")
      expect(Dir.children(File.join(work, ".git")).grep(/hecks-push-rehearsal.*tmp/)).to be_empty
      expect(File.read(file)).to start_with(git("rev-parse", "main"))
    end

    it "never lets an older commit's result overwrite a newer one, saying it went by ancestry", :aggregate_failures do
      older = git("rev-parse", "main")
      newer = commit_after("second")
      write_for(newer, "red")

      expect(write_for(older, "green")).to include("kept the record for #{newer[0, 9]}").and include("ancestor")
      expect(recorder.last).to have_attributes(commit: newer, verdict: "red")
    end

    it "lets a newer commit replace an older result" do
      older = git("rev-parse", "main")
      write_for(older)
      commit("second")
      write_for(git("rev-parse", "main"), "red")

      expect(recorder.last.verdict).to eq("red")
    end

    # A side branch whose only commit is dated long ago, parted from main.
    def parted_from_main
      base = git("rev-parse", "main")
      late = commit_after("late-branch")
      git("checkout", "-q", "-b", "side", base)
      commit("early-side")
      long_ago = { "GIT_COMMITTER_DATE" => "2001-01-01T00:00:00" }
      git("commit", "-q", "--amend", "--no-edit", env: IDENTITY.merge(long_ago))
      late
    end

    it "compares by commit time when neither commit descends from the other", :aggregate_failures do
      late = parted_from_main
      write_for(late)

      expect(write_for(git("rev-parse", "side"))).to include("by commit time")
      expect(recorder.last.commit).to eq(late)
    end
  end

  describe "the line of rehearsals" do
    let(:rehearsing) { described_class.new }
    let(:stage_runs) { [] }
    let(:during_stage) { nil }

    before do
      allow(Hecks::Adapters::GitRehearsal::Stages).to receive(:new) do
        instance_double(Hecks::Adapters::GitRehearsal::Stages).tap do |stages|
          allow(stages).to receive(:run) do
            stage_runs << git("rev-parse", "main")
            during_stage&.call
            [stage("quick", true)]
          end
        end
      end
    end

    # Two lands arriving while the first rehearsal's stages run, each refused as pending.
    def land_twice
      Array.new(2) do |n|
        commit("landed#{n}")
        described_class.new.trial(checkout: { value: work })
      rescue Hecks::Adapters::ConsoleCapture::Failure => e
        e.message
      end
    end

    context "when a land arrives while a rehearsal runs" do
      let(:during_stage) { -> { @landings = land_twice if stage_runs.size == 1 } }

      it "marks each pending, and the running rehearsal runs once more for the latest main", :aggregate_failures do
        first = git("rev-parse", "main")
        answer = rehearsing.trial(checkout: { value: work })

        expect(@landings).to all(match(/\Apending: rehearse \h{9}/))
        expect(stage_runs).to eq([first, git("rev-parse", "main")])
        expect(answer[:rehearsed]).to eq(value: git("rev-parse", "main"))
      end
    end

    # A bench a killed rehearsal left registered, and an unrelated worktree.
    def stale_bench_and_other
      bench = File.join(Dir.mktmpdir("hecks-push-rehearsal"), "bench")
      git("worktree", "add", "-q", "--detach", bench, "main")
      git("worktree", "add", "-q", "--detach", File.join(scratch, "other-worktree"), "main")
      bench
    end

    it "removes a bench a killed rehearsal left registered, and only those", :aggregate_failures do
      bench = stale_bench_and_other
      rehearsing.trial(checkout: { value: work })

      expect(git("worktree", "list", "--porcelain")).not_to include(bench)
      expect(git("worktree", "list", "--porcelain")).to include("other-worktree")
      expect(File.exist?(bench)).to be(false)
    end

    it "leaves no bench registered after a stage fails", :aggregate_failures do
      allow(Hecks::Adapters::GitRehearsal::Stages).to receive(:new).and_raise(RuntimeError, "stage blew up")

      expect { rehearsing.trial(checkout: { value: work }) }.to raise_error(RuntimeError, "stage blew up")
      expect(git("worktree", "list", "--porcelain").scan("worktree ").size).to eq(1)
    end
  end
end
