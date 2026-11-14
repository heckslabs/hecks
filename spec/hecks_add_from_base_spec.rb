require "spec_helper"
require "tmpdir"
require "open3"
require "hecks/hecks/adapters/delivery_library"
Hecks::Adapters::DeliveryLibrary.require("git_worktree_add")

# Opening a linked worktree from a base other than main, against a real repository in a temporary
# directory. Local main is the one ref every example checks it did not move.
RSpec.describe "opening a worktree from a base" do
  let(:repo) { File.realpath(Dir.mktmpdir("hecks-add-base")) }
  let(:adder) { Hecks::Adapters::GitWorktreeAdd.new }

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

  def failure = Hecks::Adapters::ConsoleCapture::Failure

  before do
    git(repo, "init", "-q", "-b", "main")
    File.write(File.join(repo, "a.rb"), "one\n")
    git(repo, "add", "a.rb")
    git(repo, "commit", "-q", "-m", "base")
    git(repo, "checkout", "-q", "-b", "side")
    File.write(File.join(repo, "b.rb"), "two\n")
    git(repo, "add", "b.rb")
    git(repo, "commit", "-q", "-m", "side")
    @side = git(repo, "rev-parse", "HEAD")
    git(repo, "checkout", "-q", "main")
    @main = git(repo, "rev-parse", "main")
  end

  it "cuts the branch from the base named and leaves local main where it was", :aggregate_failures do
    adder.create(checkout: repo, branch: "work-b", base: "side")
    expect(git(File.join(repo, ".claude", "worktrees", "work-b"), "rev-parse", "HEAD")).to eq(@side)
    expect(git(repo, "rev-parse", "main")).to eq(@main)
  end

  it "refuses a base that is not a commit, and opens nothing", :aggregate_failures do
    expect { adder.create(checkout: repo, branch: "work-c", base: "nope") }.to raise_error(failure, /not a commit/)
    expect(git(repo, "worktree", "list")).not_to include("work-c")
  end
end
