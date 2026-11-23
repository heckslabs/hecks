require "tmpdir"
require "fileutils"
require "hecks/hecks/adapters/claude_cleaning/merged_worktrees"

# What a spec of the reap's worktree retirement does to a throwaway repository: run git in it,
# commit, seat a coder's worktree under it and sweep as the reap does, with the retirement and
# the open-Work read stood in.
module MergedWorktreesRepo
  def git(path, *args) = system("git", "-C", path, *args, out: File::NULL, err: File::NULL) || raise("git #{args}")

  def commit(path, name)
    File.write(File.join(path, name), name)
    git(path, "add", name)
    git(path, "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", name)
  end

  def seat(name)
    path = File.join(root, ".claude", "worktrees", name)
    git(root, "worktree", "add", "-q", path, "-b", name)
    path
  end

  def outside_dir = File.join(dir, "elsewhere")

  def seat_outside(name, parent: outside_dir)
    FileUtils.mkdir_p(parent)
    path = File.join(parent, name)
    git(root, "worktree", "add", "-q", path, "-b", name)
    path
  end

  def sweep(now: later, retire: ->(path) { retired << File.basename(path) }, **more)
    described_class.new(root: root, window_minutes: 30, now: -> { now }, retire: retire,
                        open: ->(name) { open_work.include?(name) }, **more).sweep
  end

  def kept = sweep[:kept].map(&:first)
end

# A throwaway repository with an `origin` and one commit on main.
RSpec.shared_context "with a repository of coder worktrees" do
  include MergedWorktreesRepo

  let(:dir)       { Dir.mktmpdir("merged-worktrees") }
  let(:root)      { File.join(dir, "repo") }
  let(:retired)   { [] }
  let(:open_work) { [] }
  let(:later)     { Time.now + (3 * 3600) }

  after { FileUtils.remove_entry(dir) }

  before do
    FileUtils.mkdir_p(root)
    git(root, "init", "-q", "-b", "main")
    commit(root, "base")
    git(dir, "clone", "-q", "--bare", root, File.join(dir, "origin.git"))
    git(root, "remote", "add", "origin", File.join(dir, "origin.git"))
    git(root, "fetch", "-q", "origin")
  end
end
