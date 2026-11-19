# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "hecks/boot_cache/sweep"

# The sweep drops the compiled-Ruby cache of a checkout that is gone, the one cache every checkout
# once shared, and a directory past the cap, and keeps the rest.
RSpec.describe Hecks::BootCache::Sweep do
  let(:scratch) { File.realpath(Dir.mktmpdir("boot-sweep")) }
  let(:main) { File.join(scratch, "main").tap { |dir| FileUtils.mkdir_p(dir) } }

  before { allow(Hecks::CacheDir).to receive(:root).and_return(File.join(scratch, "cache", "hecks")) }

  after { FileUtils.rm_rf(scratch) }

  # A checkout's cache directory holding `bytes` of compiled Ruby, claimed by `owner`.
  def cache_of(owner, bytes: 10)
    dir = Hecks::BootCache.dir(owner)
    FileUtils.mkdir_p(File.join(dir, "bootsnap"))
    File.write(File.join(dir, "bootsnap", "entry"), "x" * bytes)
    File.write(File.join(dir, Hecks::CheckoutSlug::OWNER), owner)
    dir
  end

  def worktree(name) = File.join(main, ".claude", "worktrees", name).tap { |dir| FileUtils.mkdir_p(dir) }

  def sweep(live: [main], **options) = described_class.sweep(live: live, keep: main, **options)

  it "drops the cache of a worktree git no longer lists" do
    dir = cache_of(worktree("gone"))
    sweep
    expect(File.exist?(dir)).to be(false)
  end

  it "drops the cache whose owner was removed" do
    dir = cache_of(File.join(scratch, "removed"))
    sweep
    expect(File.exist?(dir)).to be(false)
  end

  it "keeps the cache of a worktree git lists" do
    tree = worktree("listed")
    dir = cache_of(tree)
    sweep(live: [main, tree])
    expect(File.exist?(dir)).to be(true)
  end

  it "drops the one cache every checkout shared" do
    shared = File.join(Hecks::BootCache.base, "bootsnap", "compile-cache-iseq").tap { |dir| FileUtils.mkdir_p(dir) }
    sweep
    expect(File.exist?(shared)).to be(false)
  end

  it "clears a standing checkout's cache past the cap" do
    tree = worktree("big")
    dir = cache_of(tree, bytes: 100)
    sweep(live: [main, tree], cap_bytes: 50)
    expect(File.exist?(dir)).to be(false)
  end

  it "keeps the sweeping checkout's own cache past the cap" do
    dir = cache_of(main, bytes: 100)
    sweep(cap_bytes: 50)
    expect(File.exist?(dir)).to be(true)
  end

  it "reports the bytes and deletes nothing on a dry run", :aggregate_failures do
    dir = cache_of(File.join(scratch, "removed"), bytes: 40)
    expect(sweep(dry_run: true)).to be >= 40
    expect(File.exist?(dir)).to be(true)
  end
end
