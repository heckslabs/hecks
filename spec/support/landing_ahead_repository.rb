require "fileutils"
require "open3"
require "tmpdir"
require_relative "landing_claims_registry"

# A throwaway repository for the landing-ahead specs: `start` cuts a branch in its own worktree
# with one committed file, `started` says which work items are started over `lib/x`, and `land`
# lands a branch onto main through one `GitLanding`.
module LandingAheadRepository
  def dir = @dir ||= File.realpath(Dir.mktmpdir("hecks-landing-ahead"))

  def repo = File.join(dir, "main")

  def tree(branch) = File.join(dir, branch)

  def git(*, chdir: repo)
    out, status = Open3.capture2e("git", "-c", "user.name=t", "-c", "user.email=t@t", *, chdir: chdir)
    raise out unless status.success?

    out
  end

  def commit(where, file, text = file)
    FileUtils.mkdir_p(File.dirname(File.join(where, file)))
    File.write(File.join(where, file), text)
    git("add", ".", chdir: where)
    git("commit", "-m", file, chdir: where)
  end

  def build_repo
    FileUtils.mkdir_p(repo)
    git("init", "-b", "main")
    commit(repo, "README")
  end

  def start(branch, file)
    git("worktree", "add", "-b", branch, tree(branch))
    commit(tree(branch), file)
  end

  # Two work items started over `lib/x`: `a` has committed `lib/x/a.rb`, and `b` has a worktree
  # and no commit yet, so it holds the whole area it was planned with.
  def two_in_one_area
    build_repo
    start("a", "lib/x/a.rb")
    git("worktree", "add", "-b", "b", tree("b"))
    started("a", "b")
  end

  def started(*keys)
    items = keys.map { |key| { key: key, area: ["lib/x"] } }
    allow(Hecks::Adapters::StartedWork).to receive(:items).and_return(items)
  end

  def land(branch)
    @landing ||= Hecks::Adapters::GitLanding.new(registry: LandingClaimsRegistry.landing_claims_registry)
    @landing.merge(checkout: repo, branch: branch).dig(:report, :value)
  end
end
