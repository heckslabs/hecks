require "tmpdir"
require "fileutils"
require "hecks/agents/adapters/sweeping/worktrees"

# A scratch repository with one commit on `main`, under a temporary directory, and helpers to add
# worktrees to it. The sweep's worktree specs share it.
RSpec.shared_context "with a scratch worktree repo" do
  let(:root)  { Dir.mktmpdir }
  let(:repo)  { File.join(root, "repo") }
  let(:shell) { Hecks::Adapters::Shell.new }

  def git(*args, dir: repo) = system("git", "-C", dir, *args, out: File::NULL, err: File::NULL, exception: true)

  def commit(dir, name)
    File.write(File.join(dir, name), name)
    git("add", name, dir: dir)
    git("commit", "-m", name, dir: dir)
  end

  def tree(branch, path: File.join(root, branch)) = git("worktree", "add", "-b", branch, path, "main").then { path }

  def detached(name) = File.join(root, name).tap { |path| git("worktree", "add", "--detach", path, "main") }

  def temp(clock: -> { Time.now + 172_800 }, roots: [root])
    Hecks::Adapters::Sweeping::Worktrees::TempKind.new(roots: roots, idle: 86_400, clock: clock)
  end

  def judged(temp:)
    Hecks::Adapters::Sweeping::Worktrees.new(shell: shell, repo: repo, temp: temp).lines.first
  end

  before do
    FileUtils.mkdir_p(repo)
    git("init", "-b", "main")
    git("config", "user.email", "a@b.c")
    git("config", "user.name", "a")
    commit(repo, "base")
  end

  after { FileUtils.remove_entry(root) }
end
