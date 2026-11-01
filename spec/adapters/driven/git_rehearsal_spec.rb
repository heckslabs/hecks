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
      expect(due).to eq("push due: no; main is level with origin/main; last rehearsal: none yet")
    end

    it "counts the unpushed commits and ages the oldest in hours" do
      commit("second", hours_ago: 5)
      commit("third")

      expect(due).to include("push due: yes; 2 commit(s) ahead of origin/main; oldest unpushed 5.0 hours old")
    end

    it "reads back the last rehearsal" do
      commit("second")
      record("red", [stage("unguarded_push", false)])

      expect(due).to include("last rehearsal: red (unguarded_push) on #{git("rev-parse", "main")[0, 9]} (the current main)")
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

        expect(due).to include("last rehearsal: red (unguarded_push)")
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
end
