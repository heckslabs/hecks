# frozen_string_literal: true

require "spec_helper"
require "hecks/hecks/adapters/landing/retired_caches"
require "tmpdir"
require "open3"

# A retired worktree takes its Cargo slot and compiled-Ruby cache with it, whichever command
# retires it. Every example builds its own throwaway repository and its own cache directory; the
# real repository and the real cache are never read.
RSpec.describe Hecks::Adapters::Landing::RetiredCaches do
  let(:dir) { File.realpath(Dir.mktmpdir("hecks-retired-caches")) }
  let(:repo) { File.join(dir, "main") }
  let(:tree) { File.join(dir, "tree") }
  let(:landing) { Hecks::Adapters::GitLanding.new }

  around do |example|
    saved = ENV.fetch("XDG_CACHE_HOME", nil)
    ENV["XDG_CACHE_HOME"] = File.join(dir, "cache")
    Hecks::CacheDir.reset!
    example.run
  ensure
    saved ? ENV["XDG_CACHE_HOME"] = saved : ENV.delete("XDG_CACHE_HOME")
    Hecks::CacheDir.reset!
    FileUtils.rm_rf(dir)
  end

  def git(*args, chdir: repo)
    out, status = Open3.capture2e("git", "-c", "user.name=t", "-c", "user.email=t@t", *args, chdir: chdir)
    raise out unless status.success?

    out
  end

  def commit(where, file)
    File.write(File.join(where, file), "x")
    git("add", ".", chdir: where)
    git("commit", "-m", file, chdir: where)
  end

  # A repository with a linked worktree on `work/a`, holding the commits named, and the caches
  # of that worktree made.
  def build_repo(*files)
    FileUtils.mkdir_p(repo)
    git("init", "-b", "main")
    commit(repo, "README")
    git("worktree", "add", "-b", "work/a", tree)
    files.each { |file| commit(tree, file) }
    FileUtils.mkdir_p(caches_of(tree))
  end

  def caches_of(root)
    [Hecks::RustBuild::TargetDir.shared(Hecks::CheckoutSlug.slug(root)), Hecks::BootCache.dir(root)]
  end

  def standing(root = tree) = caches_of(root).map { |cache| File.exist?(cache) }

  it "is in force on the vendored tidy" do
    expect(Hecks::Adapters::GitLanding::Tidy.ancestors.first).to eq(described_class)
  end

  it "removes the Cargo slot and compiled-Ruby cache of a worktree it retires", :aggregate_failures do
    build_repo
    landing.remove(checkout: tree)
    expect(File.exist?(tree)).to be(false)
    expect(standing).to eq([false, false])
  end

  it "removes them when a landing tidies the worktree it landed from", :aggregate_failures do
    build_repo("a.rb")
    landing.merge(checkout: repo, branch: "work/a")
    expect(File.exist?(tree)).to be(false)
    expect(standing).to eq([false, false])
  end

  it "removes them when a branch is discarded, and still says what was discarded", :aggregate_failures do
    build_repo("a.rb")
    said = landing.drop_branch(checkout: tree, reason: "superseded").dig(:report, :value)
    expect(said).to include("removed #{tree}", "reason: superseded")
    expect(standing).to eq([false, false])
  end

  it "keeps the caches of a worktree the retirement refuses", :aggregate_failures do
    build_repo
    File.write(File.join(tree, "scratch.txt"), "unsaved")
    expect { landing.remove(checkout: tree) }.to raise_error(Hecks::Adapters::ConsoleCapture::Failure, /is kept/)
    expect(standing).to eq([true, true])
  end

  it "leaves another worktree's caches alone" do
    build_repo
    git("worktree", "add", "-b", "work/b", other = File.join(dir, "other"))
    FileUtils.mkdir_p(caches_of(other))
    landing.remove(checkout: tree)
    expect(standing(other)).to eq([true, true])
  end
end
