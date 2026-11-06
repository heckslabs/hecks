require "spec_helper"
require "tmpdir"
require "open3"
require "hecks/hecks/adapters/git_pick"

# Picking a commit onto a worktree's branch, run against a real repository in a temporary directory.
# Each example builds its own repository, so no checkout of the owner's is touched.
RSpec.describe "picking a commit onto a branch" do
  let(:repo) { File.realpath(Dir.mktmpdir("hecks-pick")) }
  let(:tree) { File.join(repo, ".claude", "worktrees", "work-a") }
  let(:picker) { Hecks::Adapters::GitPick.new }

  after { FileUtils.remove_entry(repo) }

  def git(dir, *args)
    out, status = Open3.capture2e(git_env, "git", *args, chdir: dir)
    raise "git #{args.join(" ")} failed: #{out}" unless status.success?

    out.strip
  end

  def git_env
    { "GIT_AUTHOR_NAME" => "Test", "GIT_AUTHOR_EMAIL" => "t@example.com",
      "GIT_COMMITTER_NAME" => "Test", "GIT_COMMITTER_EMAIL" => "t@example.com" }
  end

  def commit_file(dir, path, text, message)
    File.write(File.join(dir, path), text)
    git(dir, "add", path)
    git(dir, "commit", "-m", message)
    git(dir, "rev-parse", "HEAD")
  end

  def failure = Hecks::Adapters::ConsoleCapture::Failure

  # main holds a.rb; side adds b.rb; work-a is cut from main in a worktree.
  before do
    git(repo, "init", "-q", "-b", "main")
    git(repo, "config", "user.name", "Test")
    git(repo, "config", "user.email", "t@example.com")
    commit_file(repo, "a.rb", "one\n", "base")
    git(repo, "checkout", "-q", "-b", "side")
    @timeline = commit_file(repo, "b.rb", "timeline\n", "Read the timeline")
    git(repo, "checkout", "-q", "main")
    git(repo, "worktree", "add", "-q", "-b", "work-a", tree, "main")
  end

  def pick(**overrides)
    picker.apply(checkout: tree, branch: "work-a", commit: @timeline, **overrides)
  end

  it "applies the commit onto the branch and answers the sha it stands on", :aggregate_failures do
    expect(pick).to include(sha: { value: a_string_matching(/\A\h{7,}\z/) }, report: { value: a_string_including("picked") })
    expect(File.read(File.join(tree, "b.rb"))).to eq("timeline\n")
  end

  it "refuses main, and applies nothing" do
    expect { pick(branch: "main") }.to raise_error(failure, /never picked onto main/)
  end

  it "refuses a branch checked out in no worktree" do
    expect { pick(branch: "work-z") }.to raise_error(failure, /checked out in no worktree/)
  end

  it "refuses a dirty checkout by name, and applies nothing" do
    File.write(File.join(tree, "a.rb"), "edited\n")
    expect { pick }.to raise_error(failure, /has uncommitted changes/)
  end

  it "names a conflicted path, aborts, and leaves the branch as it was", :aggregate_failures do
    commit_file(tree, "b.rb", "other\n", "Clash")
    before = git(tree, "rev-parse", "HEAD")
    expect { pick }.to raise_error(failure, /conflicts in b\.rb; nothing changed/)
    expect(git(tree, "rev-parse", "HEAD")).to eq(before)
  end
end
