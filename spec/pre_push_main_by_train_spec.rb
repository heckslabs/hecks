require "spec_helper"
require "open3"
require "tmpdir"
require "hecks/hecks/adapters/git_train"

# The pre-push hook lets main through only when the push train carries it (`-c hecks.trainCarry`),
# or when the owner names a reason in HECKS_OWNER_PUSH. Temp repositories, a local bare remote, and
# a stub `bundle` so the quick gate itself is not run.
RSpec.describe "the pre-push hook on main", :io do
  REFUSAL = "main is pushed through the push train (send_train.board! checkout=".freeze

  OVERRIDE = "HECKS_OWNER_PUSH=<reason>".freeze

  let(:scratch) { Dir.mktmpdir("hecks-main-by-train") }
  let(:work) { File.join(scratch, "work") }
  let(:hooks) { File.expand_path("../.githooks", __dir__) }

  def run(*args, env: {}, dir: work)
    full = { "GIT_AUTHOR_NAME" => "A", "GIT_AUTHOR_EMAIL" => "a@x.test", "GIT_COMMITTER_NAME" => "A",
             "GIT_COMMITTER_EMAIL" => "a@x.test", "PATH" => "#{File.join(scratch, "bin")}:#{ENV.fetch("PATH")}" }
    Open3.capture3(full.merge(env), "git", *args, chdir: dir)
  end

  def git(*args, **opts) = run(*args, **opts).tap { |_o, e, s| raise "git #{args}: #{e}" unless s.success? }.first

  def push(*args, **opts) = run("push", "-q", "origin", *args, **opts)

  def with_stub_bundle
    path = ENV.fetch("PATH")
    ENV["PATH"] = "#{File.join(scratch, "bin")}:#{path}"
    yield
  ensure
    ENV["PATH"] = path
  end

  def commit(name)
    File.write(File.join(work, name), name)
    git("add", name)
    git("commit", "-q", "-m", name)
  end

  before do
    FileUtils.mkdir_p(File.join(scratch, "bin"))
    File.write(File.join(scratch, "bin/bundle"), "#!/bin/sh\nexit 0\n")
    FileUtils.chmod(0o755, File.join(scratch, "bin/bundle"))
    git("init", "-q", "--bare", "-b", "main", "origin.git", dir: scratch)
    git("clone", "-q", "origin.git", work, dir: scratch)
    git("checkout", "-q", "-b", "main")
    git("config", "core.hooksPath", hooks)
    commit("first")
  end

  after { FileUtils.remove_entry(scratch) }

  it "refuses a push of main that no train carries, with the board command" do
    _out, err, status = push("main")

    expect([status.success?, err]).to match([false, include(REFUSAL, "a plain git push of main is refused", OVERRIDE)])
  end

  it "pushes nothing when it refuses" do
    push("main")

    expect(git("ls-remote", "origin", "refs/heads/main")).to be_empty
  end

  it "refuses an empty owner override" do
    _out, _err, status = push("main", env: { "HECKS_OWNER_PUSH" => "" })

    expect(status.success?).to be(false)
  end

  it "lets a push the train carries through" do
    _out, _err, status = run("-c", "hecks.trainCarry=#{git("rev-parse", "main").strip}", "push", "-q", "origin", "main")

    expect(status.success?).to be(true)
  end

  it "lets the owner's named reason through and prints it", :aggregate_failures do
    _out, err, status = push("main", env: { "HECKS_OWNER_PUSH" => "rescue the remote" })

    expect(status.success?).to be(true)
    expect(err).to include("owner push of main outside the train: rescue the remote")
  end

  it "leaves another branch and a tag alone", :aggregate_failures do
    git("tag", "v0")

    expect(push("HEAD:refs/heads/topic")[2].success?).to be(true)
    expect(push("refs/tags/v0")[2].success?).to be(true)
  end

  it "runs nothing for a lane whose row names no gate, and does not ask for the train", :aggregate_failures do
    _out, _err, status = push("HEAD:refs/heads/stable")

    expect(status.success?).to be(true)
    expect(push("HEAD:refs/heads/stable")[0]).not_to include("push train")
  end

  it "refuses to pass a push unchecked when the lane table is missing" do
    FileUtils.cp_r(hooks, File.join(scratch, "hooks"))
    FileUtils.rm(File.join(scratch, "hooks/pre-push.lanes"))
    git("config", "core.hooksPath", File.join(scratch, "hooks"))
    _out, err, status = push("main")

    expect([status.success?, err]).to match([false, include("pre-push.lanes is missing")])
  end

  it "is satisfied by the train's own carry" do
    git("push", "-q", "--no-verify", "origin", "main")
    commit("second")
    carriage = Hecks::Adapters::GitTrain::Carriage.new(Hecks::Adapters::Git.new, work, branch: "main", remote: "origin")
    with_stub_bundle { carriage.carry(git("rev-parse", "main").strip) }

    expect(git("ls-remote", "origin", "refs/heads/main")).to start_with(git("rev-parse", "main").strip)
  end
end
