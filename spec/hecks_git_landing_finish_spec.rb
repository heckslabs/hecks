require "spec_helper"
require "hecks/hecks/adapters/git_landing"
require "tmpdir"
require "open3"

# Finishing a branch is one step that refuses by name at the first failure. Every example builds
# its own throwaway repository and stands in for the gate; the real one is never read or run.
RSpec.describe Hecks::Adapters::GitLanding, "#finish_branch" do
  let(:dir) { File.realpath(Dir.mktmpdir("hecks-landing-finish")) }
  let(:repo) { File.join(dir, "main") }
  let(:tree) { File.join(dir, "tree") }
  let(:failure) { Hecks::Adapters::ConsoleCapture::Failure }

  def result(out, success) = Hecks::Adapters::Shell::Result.new(out, "", instance_double(Process::Status, success?: success))

  def green = result("{\"status\": \"completed\"}", true)

  def red = result("{\"status\": \"faulted\"}", false)

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

  def build_repo
    FileUtils.mkdir_p(repo)
    git("init", "-b", "main")
    git("config", "user.name", "t")
    git("config", "user.email", "t@t")
    commit(repo, "README")
    git("worktree", "add", "-b", "work/a", tree)
    commit(tree, "a.txt")
  end

  def build_repo_with_stale_marker
    build_repo
    File.join(repo, ".git", "hecks-red-flag.json").tap { |path| File.write(path, "{}") }
  end

  def finish(gate, **tune) = described_class.new(**tune).finish_branch(checkout: tree, branch: "work/a", onto: "main", gate: gate)

  it "rebases onto a main that moved, lands it and removes the worktree", :aggregate_failures do
    build_repo
    commit(repo, "later.txt")
    finish(->(_dir) { green })

    expect(git("log", "--format=%s", "main")).to include("a.txt")
    expect(File.directory?(tree)).to be(false)
  end

  it "refuses a red gate by name and lands nothing", :aggregate_failures do
    build_repo

    expect { finish(->(_dir) { red }) }.to raise_error(failure, /gate red/)
    expect(git("log", "--format=%s", "main")).not_to include("a.txt")
  end

  it "refuses a conflicting rebase by name and leaves the branch as it was", :aggregate_failures do
    build_repo
    commit(tree, "same.txt", "mine")
    commit(repo, "same.txt", "theirs")

    expect { finish(->(_dir) { green }) }.to raise_error(failure, /conflict.*same\.txt/)
    expect(git("status", "--porcelain", chdir: tree)).to eq("")
  end

  it "refuses unsaved work by name" do
    build_repo
    File.write(File.join(tree, "wip.txt"), "x")

    expect { finish(->(_dir) { green }) }.to raise_error(failure, /unsaved work/)
  end

  it "records the gate verdict for the commit main names and says so", :aggregate_failures do
    build_repo
    said = finish(->(_dir) { green })
    marker = described_class::GateMarker.read(File.join(repo, ".git"))

    expect(said[:report][:value]).to include("tests: quick gate green")
    expect(marker).to include("sha" => git("rev-parse", "main").strip, "verdict" => "green")
  end

  it "lands with a stale red-flag marker in the git directory and leaves the file alone", :aggregate_failures do
    stale = build_repo_with_stale_marker
    finish(->(_dir) { green })

    expect(git("log", "--format=%s", "main")).to include("a.txt")
    expect(File.read(stale)).to eq("{}")
  end

  it "refuses a primary checkout in the middle of a rebase by name and leaves main as it was", :aggregate_failures do
    build_repo
    before = git("rev-parse", "main").strip
    FileUtils.mkdir_p(File.join(repo, ".git", "rebase-merge"))

    expect { finish(->(_dir) { green }) }.to raise_error(failure, /middle of a rebase/)
    expect(git("rev-parse", "main").strip).to eq(before)
  end

  it "refuses a dirty primary checkout by name and leaves main as it was", :aggregate_failures do
    build_repo
    before = git("rev-parse", "main").strip
    File.write(File.join(repo, "README"), "edited")

    expect { finish(->(_dir) { green }) }.to raise_error(failure, /README/)
    expect(git("rev-parse", "main").strip).to eq(before)
  end

  it "refuses by name while another landing is in flight" do
    build_repo
    git_dir = git("rev-parse", "--path-format=absolute", "--git-common-dir").strip
    held = described_class::Line.new(git_dir).join("work/other", ready: true)

    expect { finish(->(_dir) { green }, wait_minutes: 0.02, say: ->(_text) {}) }.to raise_error(failure, /queue busy/)
    held.close
  end
end
