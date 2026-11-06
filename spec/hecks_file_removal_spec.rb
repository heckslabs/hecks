require "spec_helper"
require "tmpdir"
require "open3"
require "hecks/hecks/adapters/git_file_removal"

# Removing a path from a checkout: what the adapter removes, and each thing it refuses by name. Every
# example builds a throwaway repository, so nothing outside the temporary directory can be touched.
RSpec.describe "Removal.Remove" do
  let(:dir) { File.realpath(Dir.mktmpdir("hecks-file-removal")) }
  let(:remover) { Hecks::Adapters::GitFileRemoval.new }

  after { FileUtils.remove_entry(dir) }

  def repo = File.join(dir, "repo")

  def outside = File.join(dir, "outside")

  def failure = Hecks::Adapters::ConsoleCapture::Failure

  def git(*args, chdir: repo)
    out, status = Open3.capture2e("git", "-c", "user.name=t", "-c", "user.email=t@t", *args, chdir: chdir)
    raise out unless status.success?

    out.strip
  end

  def write(where, file, text = file)
    path = File.join(where, file)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, text)
  end

  # The primary checkout has one tracked file, README, and a tracked directory, docs/.
  before do
    FileUtils.mkdir_p([repo, outside])
    git("init", "-b", "main", repo, chdir: dir)
    write(repo, "README")
    write(repo, "docs/guide.md")
    git("add", ".")
    git("commit", "-m", "start")
    write(outside, "precious")
  end

  def tree
    File.join(repo, ".claude", "worktrees", "work-a").tap do |path|
      git("worktree", "add", "-b", "work-a", path, "main")
    end
  end

  it "removes an untracked file from the primary checkout", :aggregate_failures do
    write(repo, "scratch.txt")
    answer = remover.delete(checkout: repo, path: "scratch.txt")
    expect(File.exist?(File.join(repo, "scratch.txt"))).to be(false)
    expect(answer[:path]).to eq(value: "scratch.txt")
    expect(answer[:report][:value]).to include("removed scratch.txt")
  end

  it "takes an absolute path inside the checkout" do
    write(repo, "scratch.txt")
    remover.delete(checkout: repo, path: File.join(repo, "scratch.txt"))
    expect(File.exist?(File.join(repo, "scratch.txt"))).to be(false)
  end

  it "removes a tracked file from a linked worktree" do
    path = tree
    remover.delete(checkout: path, path: "README")
    expect(File.exist?(File.join(path, "README"))).to be(false)
  end

  it "refuses a tracked file in the primary checkout", :aggregate_failures do
    expect { remover.delete(checkout: repo, path: "README") }.to raise_error(failure, /tracked in the primary checkout/)
    expect(File.exist?(File.join(repo, "README"))).to be(true)
  end

  it "refuses a tracked directory in the primary checkout even when told it is a directory", :aggregate_failures do
    expect { remover.delete(checkout: repo, path: "docs", directory: { value: true }) }
      .to raise_error(failure, /tracked in the primary checkout/)
    expect(File.exist?(File.join(repo, "docs", "guide.md"))).to be(true)
  end

  it "refuses a path that climbs out of the checkout with ..", :aggregate_failures do
    expect { remover.delete(checkout: repo, path: "../outside/precious") }.to raise_error(failure, /not inside/)
    expect(File.exist?(File.join(outside, "precious"))).to be(true)
  end

  it "refuses an absolute path outside the checkout" do
    expect { remover.delete(checkout: repo, path: File.join(outside, "precious")) }.to raise_error(failure, /not inside/)
  end

  it "refuses a path reached through a symlinked directory that leads out", :aggregate_failures do
    File.symlink(outside, File.join(repo, "link"))
    expect { remover.delete(checkout: repo, path: "link/precious") }.to raise_error(failure, /not inside/)
    expect(File.exist?(File.join(outside, "precious"))).to be(true)
  end

  it "unlinks a symlink without touching what it points at", :aggregate_failures do
    File.symlink(outside, File.join(repo, "link"))
    remover.delete(checkout: repo, path: "link")
    expect(File.symlink?(File.join(repo, "link"))).to be(false)
    expect(File.exist?(File.join(outside, "precious"))).to be(true)
  end

  it "refuses a directory unless it is told to remove one", :aggregate_failures do
    write(repo, "build/out.txt")
    expect { remover.delete(checkout: repo, path: "build") }.to raise_error(failure, /is a directory/)
    expect(File.exist?(File.join(repo, "build", "out.txt"))).to be(true)
  end

  it "removes a directory with what is in it when told to" do
    write(repo, "build/out.txt")
    remover.delete(checkout: repo, path: "build", directory: { value: true })
    expect(File.exist?(File.join(repo, "build"))).to be(false)
  end

  it "refuses .git", :aggregate_failures do
    expect { remover.delete(checkout: repo, path: ".git", directory: { value: true }) }.to raise_error(failure, /\.git/)
    expect { remover.delete(checkout: repo, path: ".git/HEAD") }.to raise_error(failure, /\.git/)
    expect(File.exist?(File.join(repo, ".git", "HEAD"))).to be(true)
  end

  it "refuses the checkout itself", :aggregate_failures do
    expect { remover.delete(checkout: repo, path: ".", directory: { value: true }) }.to raise_error(failure, /the checkout itself/)
    expect(File.exist?(File.join(repo, "README"))).to be(true)
  end

  it "refuses a directory that holds another checkout", :aggregate_failures do
    path = tree
    expect { remover.delete(checkout: repo, path: ".claude", directory: { value: true }) }
      .to raise_error(failure, /holds another checkout/)
    expect(File.directory?(path)).to be(true)
  end

  it "refuses a path that is not there" do
    expect { remover.delete(checkout: repo, path: "nothing.txt") }.to raise_error(failure, /does not exist/)
  end

  it "refuses a missing path name" do
    expect { remover.delete(checkout: repo, path: "  ") }.to raise_error(failure, /no path named/)
  end

  it "does not expand a pattern", :aggregate_failures do
    write(repo, "a.tmp")
    write(repo, "b.tmp")
    expect { remover.delete(checkout: repo, path: "*.tmp") }.to raise_error(failure, /does not exist/)
    expect(File.exist?(File.join(repo, "a.tmp"))).to be(true)
  end

  it "refuses a directory that is not a repository" do
    expect { remover.delete(checkout: outside, path: "precious") }.to raise_error(failure)
    expect(File.exist?(File.join(outside, "precious"))).to be(true)
  end
end
