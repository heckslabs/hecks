require "spec_helper"
require "fileutils"
require "open3"
require "tmpdir"
require "hecks/hecks/adapters/pushing"
require "hecks/hecks/adapters/git_train"

# The pusher lock: one session boards the push train. Every example builds its own repository and
# its own session identity, so the real .git, ~/.claude and GitHub are never touched.
RSpec.describe "the pusher lock" do
  let(:dir) { File.realpath(Dir.mktmpdir("hecks-pusher-lock")) }
  let(:repo) { File.join(dir, "work") }
  let(:origin) { File.join(dir, "origin.git") }
  let(:pushing) { Hecks::Adapters::Pushing.new(checkout: repo) }
  let(:marker) { File.join(repo, ".git", "hecks-pusher") }

  after { FileUtils.remove_entry(dir) }

  def git(*args, chdir: repo)
    out, status = Open3.capture2e("git", "-c", "user.name=Ann", "-c", "user.email=a@t", *args, chdir: chdir)
    raise out unless status.success?

    out
  end

  def open_repository
    git("init", "-q", "--bare", "-b", "main", origin, chdir: dir)
    git("clone", "-q", origin, repo, chdir: dir)
    git("commit", "--allow-empty", "-q", "-m", "start")
    git("push", "-q", "origin", "main")
  end

  def session(id) = { "CLAUDE_JOB_DIR" => "/jobs/#{id}" }

  def board(id) = Hecks::Adapters::GitTrain.new(env: session(id)).carry(checkout: repo)

  before { open_repository }

  it "assigns the pusher and names it", :aggregate_failures do
    pushing.mark(session: { value: "s1" })

    expect(File.read(marker)).to eq("s1\n")
    expect(pushing.current[:text]).to eq("the pusher is s1\n")
  end

  it "replaces the pusher when assigned twice" do
    pushing.mark(session: "s1")
    pushing.mark(session: "s2")

    expect(File.read(marker)).to eq("s2\n")
  end

  it "reads a session's identity from the basename of its job directory" do
    expect(Hecks::Adapters::PusherMarker.caller_id(session("9baa06a2"))).to eq("9baa06a2")
  end

  it "lets the assigned pusher through the check" do
    pushing.mark(session: "s1")
    guard = Hecks::Adapters::PusherGuard.new(File.join(repo, ".git"), env: session("s1"))

    expect { guard.boarding! }.not_to raise_error
  end

  it "refuses another session, naming the pusher, and pushes nothing", :aggregate_failures do
    git("commit", "--allow-empty", "-q", "-m", "local")
    pushing.mark(session: "s1")

    expect { board("s2") }.to raise_error(Hecks::Adapters::ConsoleCapture::Failure, "only the pusher boards: s1")
    expect(git("rev-parse", "main", chdir: origin)).not_to eq(git("rev-parse", "main"))
  end

  it "refuses a caller outside any session" do
    pushing.mark(session: "s1")

    expect { Hecks::Adapters::GitTrain.new(env: {}).carry(checkout: repo) }
      .to raise_error(Hecks::Adapters::ConsoleCapture::Failure, /only the pusher boards: s1/)
  end

  it "does not lock a repository with no pusher assigned", :aggregate_failures do
    guard = Hecks::Adapters::PusherGuard.new(File.join(repo, ".git"), env: session("anyone"))

    expect { guard.boarding! }.not_to raise_error
    expect(pushing.current[:text]).to include("no pusher is assigned")
  end

  def land_branch
    git("checkout", "-q", "-b", "work/x")
    File.write(File.join(repo, "a.rb"), "a")
    git("add", "a.rb")
    git("commit", "-q", "-m", "add a")
    git("checkout", "-q", "main")
    git("merge", "--no-ff", "-q", "-m", "Merge branch 'work/x'", "work/x")
  end

  it "lists what landed on local main and waits to be pushed, with the branch and files" do
    land_branch

    expect(pushing.waiting[:text]).to include("add a", "Merge branch 'work/x'", "landed from work/x", "a.rb")
  end

  it "says nothing waits when local main is on origin" do
    expect(pushing.waiting[:text]).to eq("nothing waits: local main is on origin\n")
  end
end
