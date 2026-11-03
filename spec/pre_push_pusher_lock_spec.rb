require "spec_helper"
require "open3"
require "tmpdir"

# The pre-push hook lets main through the push train only for the assigned pusher: the marker
# `hecks-pusher` in the git directory holds its session id, the basename of CLAUDE_JOB_DIR. No
# marker means no lock, and the owner's HECKS_OWNER_PUSH still passes. Temporary repositories, a
# local bare remote and a stub `bundle`, so the quick gate itself is not run.
RSpec.describe "the pre-push hook and the pusher lock", :io do
  let(:scratch) { Dir.mktmpdir("hecks-pusher-hook") }
  let(:work) { File.join(scratch, "work") }
  let(:hooks) { File.expand_path("../.githooks", __dir__) }

  def run(*args, env: {})
    full = { "GIT_AUTHOR_NAME" => "A", "GIT_AUTHOR_EMAIL" => "a@x.test", "GIT_COMMITTER_NAME" => "A",
             "GIT_COMMITTER_EMAIL" => "a@x.test", "PATH" => "#{File.join(scratch, "bin")}:#{ENV.fetch("PATH")}" }
    Open3.capture3(full.merge(env), "git", *args, chdir: work)
  end

  def git(*args) = run(*args).tap { |_o, e, s| raise "git #{args}: #{e}" unless s.success? }.first

  def carry(env: {})
    run("-c", "hecks.trainCarry=#{git("rev-parse", "main").strip}", "push", "-q", "origin", "main", env: env)
  end

  def assign(id) = File.write(File.join(work, ".git", "hecks-pusher"), "#{id}\n")

  before do
    FileUtils.mkdir_p(File.join(scratch, "bin"))
    File.write(File.join(scratch, "bin/bundle"), "#!/bin/sh\nexit 0\n")
    FileUtils.chmod(0o755, File.join(scratch, "bin/bundle"))
    Open3.capture3("git", "init", "-q", "--bare", "-b", "main", "origin.git", chdir: scratch)
    Open3.capture3("git", "clone", "-q", "origin.git", work, chdir: scratch)
    git("checkout", "-q", "-b", "main")
    git("config", "core.hooksPath", hooks)
    git("commit", "--allow-empty", "-q", "-m", "first")
  end

  after { FileUtils.remove_entry(scratch) }

  it "lets the assigned pusher's boarding through" do
    assign("s1")

    expect(carry(env: { "CLAUDE_JOB_DIR" => "/jobs/s1" })[2].success?).to be(true)
  end

  it "refuses another session, naming the pusher", :aggregate_failures do
    assign("s1")
    _out, err, status = carry(env: { "CLAUDE_JOB_DIR" => "/jobs/s2" })

    expect(status.success?).to be(false)
    expect(err).to include("only the pusher boards: s1")
  end

  it "lets the owner's named reason through" do
    assign("s1")

    expect(carry(env: { "HECKS_OWNER_PUSH" => "rescue" })[2].success?).to be(true)
  end

  it "does not lock a repository with no pusher assigned" do
    expect(carry(env: { "CLAUDE_JOB_DIR" => "/jobs/anyone" })[2].success?).to be(true)
  end
end
