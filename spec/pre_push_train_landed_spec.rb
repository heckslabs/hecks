# frozen_string_literal: true

require "spec_helper"
require_relative "support/train_scratch_repo"

# A train whose tip passed the landing's quick gate is pushed without the quick stage run again,
# but only when the mark (`hecks.trainLanded`) names the commit carried and the landing's gate
# marker names it green.
# A stub `bundle` records each call, so the stage itself is not run.
RSpec.describe "the pre-push hook on a landed train", :io do
  include TrainScratchRepo

  let(:calls) { File.join(repo, "calls") }
  let(:origin) { File.join(repo, "origin.git") }
  let(:work) { File.join(repo, "work") }

  def git_env = { "PATH" => "#{File.join(repo, "bin")}:#{ENV.fetch("PATH")}" }

  def board(sha, landed:)
    marks = ["-c", "hecks.trainCarry=#{sha}"]
    marks += ["-c", "hecks.trainLanded=#{landed}"] if landed
    git(*marks, "push", "-q", "origin", "main", dir: work)
  end

  def quick_runs = File.readlines(calls).count { |line| line.include?("gate") }

  def stub_bundle
    FileUtils.mkdir_p(File.join(repo, "bin"))
    File.write(File.join(repo, "bin/bundle"), "#!/bin/sh\necho \"$@\" >> #{calls}\nexit 0\n")
    FileUtils.chmod(0o755, File.join(repo, "bin/bundle"))
  end

  def clone_with_hook
    git("init", "-q", "--bare", "-b", "main", origin)
    git("clone", "-q", origin, work)
    git("checkout", "-q", "-b", "main", dir: work)
    git("config", "core.hooksPath", File.expand_path("../.githooks", __dir__), dir: work)
    commit("first", dir: work)
  end

  before do
    stub_bundle
    clone_with_hook
    File.write(calls, "")
  end

  after { FileUtils.remove_entry(repo) }

  it "skips the quick stage when the mark and the gate marker name the commit" do
    mark_in(head_of_work)
    board(head_of_work, landed: head_of_work)

    expect(quick_runs).to eq(0)
  end

  it "still runs the stub check, which is not a re-run" do
    mark_in(head_of_work)
    board(head_of_work, landed: head_of_work)

    expect(File.read(calls)).to include("stub_scope")
  end

  it "runs the quick stage when the gate marker does not name the commit" do
    board(head_of_work, landed: head_of_work)

    expect(quick_runs).to eq(1)
  end

  it "runs the quick stage when the push carries no landed mark" do
    mark_in(head_of_work)
    board(head_of_work, landed: nil)

    expect(quick_runs).to eq(1)
  end

  def head_of_work = git("rev-parse", "HEAD", dir: work)

  def mark_in(sha)
    File.write(File.join(work, ".git", "hecks-local-main-gate.json"), JSON.generate("sha" => sha, "verdict" => "green"))
  end
end
