require "spec_helper"
require "hecks/hecks/adapters/git_landing"
require "tmpdir"
require "open3"

# A submitted landing is handed to a job and answered at once: the adapter starts one process that
# runs the landing through the primary checkout's launcher, standing in the primary checkout. Each
# example builds its own throwaway repository and stands in for the spawn, so no process starts.
RSpec.describe Hecks::Adapters::GitLanding, "#start_landing" do
  let(:dir) { File.realpath(Dir.mktmpdir("hecks-landing-job")) }
  let(:repo) { File.join(dir, "main") }
  let(:tree) { File.join(dir, "tree") }
  let(:spawned) { [] }

  after { FileUtils.remove_entry(dir) }

  def git(*args, chdir: repo)
    out, status = Open3.capture2e("git", "-c", "user.name=t", "-c", "user.email=t@t", *args, chdir: chdir)
    raise out unless status.success?

    out
  end

  def commit(where, file, text = "x")
    File.write(File.join(where, file), text)
    git("add", ".", chdir: where)
    git("commit", "-m", file, chdir: where)
  end

  def build_repo(launcher: true)
    FileUtils.mkdir_p(repo)
    git("init", "-b", "main")
    commit(repo, "README")
    launcher_in(repo) if launcher
    git("worktree", "add", "-b", "work/a", tree)
    commit(tree, "a.txt")
  end

  def launcher_in(where)
    FileUtils.mkdir_p(File.join(where, "exe"))
    FileUtils.touch(File.join(where, "exe", "hecks"))
    FileUtils.chmod("+x", File.join(where, "exe", "hecks"))
    commit(where, "launcher")
  end

  def green
    Hecks::Adapters::Shell::Result.new("{\"status\": \"completed\"}", "", instance_double(Process::Status, success?: true))
  end

  def landing = described_class.new(spawner: ->(argv, from) { spawned << [argv, from] }, logs: File.join(dir, "logs"))

  def start = landing.start_landing(checkout: tree, branch: "work/a", onto: "main")

  it "answers handed without landing anything", :aggregate_failures do
    build_repo

    expect(start[:outcome]).to eq(value: "handed")
    expect(git("log", "--format=%s", "main")).not_to include("a.txt")
  end

  it "starts the landing through the primary checkout's launcher, standing in the primary checkout", :aggregate_failures do
    build_repo
    start
    argv, from = spawned.first

    expect(argv).to include(File.join(repo, "exe", "hecks"), "Landing.carry!", "checkout.value=#{tree}", "branch.value=work/a")
    expect(from).to eq(repo)
  end

  it "has the job land onto the same branch, confirmed and waited for" do
    build_repo
    start

    expect(spawned.first.first).to include("onto.value=main", "--confirm", "--wait")
  end

  it "names the job's log in its report" do
    build_repo

    expect(start[:report][:value]).to include(File.join(dir, "logs", "work_a.log"))
  end

  it "refuses by name when the primary checkout has no launcher, and starts nothing", :aggregate_failures do
    build_repo(launcher: false)

    expect { start }.to raise_error(Hecks::Adapters::ConsoleCapture::Failure, /no launcher/)
    expect(spawned).to be_empty
  end

  it "lands a job's branch and keeps the worktree for the review", :aggregate_failures do
    build_repo
    said = landing.carry_branch(checkout: tree, branch: "work/a", onto: "main", gate: ->(_dir) { green })

    expect(said[:report][:value]).to include("kept work/a")
    expect(File.directory?(tree)).to be(true)
  end
end
