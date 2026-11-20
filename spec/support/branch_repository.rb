require "tmpdir"
require "fileutils"
require "hecks/hecks/adapters/shell"

# A throwaway git repository with a `main` and branches that each commit some files. The group
# that includes it names `repo`, a temporary directory.
module BranchRepository
  def git(*argv)
    Hecks::Adapters::Shell.new.capture("git", "-c", "user.name=t", "-c", "user.email=t@t", *argv, chdir: repo)
  end

  def start_repository
    git("init", "-q", "-b", "main")
    commit_files("README.md")
  end

  def commit_files(*paths)
    paths.each do |path|
      FileUtils.mkdir_p(File.dirname(File.join(repo, path)))
      File.write(File.join(repo, path), "#{path}\n")
    end
    git("add", ".")
    git("commit", "-q", "-m", "change")
  end

  def branch_editing(name, *paths)
    git("checkout", "-q", "-b", name)
    commit_files(*paths)
    git("checkout", "-q", "main")
  end
end
