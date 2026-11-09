require "spec_helper"
require "tmpdir"
require "hecks/rust_build/prune"

RSpec.describe Hecks::RustBuild::Prune do
  let(:dir) { Dir.mktmpdir("prune") }

  after { FileUtils.rm_rf(dir) }

  def touch(path, age_days: 0, bytes: 10)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, "x" * bytes)
    File.utime(Time.now - (age_days * 86_400), Time.now - (age_days * 86_400), path)
    path
  end

  # Dates a directory and everything in it back, so it counts as untouched for that long.
  def back_date(path, days)
    stamp = Time.now - (days * 86_400)
    ([path] + Dir.glob(File.join(path, "**", "*"), File::FNM_DOTMATCH)).each { |entry| File.utime(stamp, stamp, entry) }
  end

  describe ".stale" do
    let!(:old) { touch(File.join(dir, "debug", "deps", "old.rlib"), age_days: 30) }
    let!(:fresh) { touch(File.join(dir, "debug", "deps", "new.rlib")) }

    it "reports the bytes of the artifacts older than the cutoff" do
      expect(described_class.stale([dir], days: 14)).to eq(10)
    end

    it "deletes the old artifact" do
      described_class.stale([dir], days: 14)
      expect(File.exist?(old)).to be(false)
    end

    it "keeps the fresh artifact" do
      described_class.stale([dir], days: 14)
      expect(File.exist?(fresh)).to be(true)
    end

    it "deletes nothing on a dry run" do
      described_class.stale([dir], days: 14, dry_run: true)
      expect(File.exist?(old)).to be(true)
    end
  end

  describe ".unlisted_slots" do
    def shared = File.join(dir, "shared")

    def live_tree = File.join(dir, "trees", "live")

    let!(:live_slot) { touch(File.join(shared, Hecks::RustBuild::SessionBuild.slug(live_tree), "debug", "a")) }
    let!(:dead_slot) { touch(File.join(shared, "gone-0123abcd", "debug", "a")) }
    let!(:crate_dir) { touch(File.join(shared, "codegen", "debug", "a")) }

    before do
      Dir.children(shared).each { |name| back_date(File.join(shared, name), 5) }
      described_class.unlisted_slots(shared, [live_tree])
    end

    it "removes the directory of a worktree git no longer lists" do
      expect(File.exist?(dead_slot)).to be(false)
    end

    it "keeps a listed worktree's directory and a crate's", :aggregate_failures do
      expect([File.exist?(live_slot), File.exist?(crate_dir)]).to eq([true, true])
    end
  end

  describe ".unlisted_slots for a slot git does not list" do
    def shared = File.join(dir, "shared")

    def make_slot(name, owner: nil, days: 5)
      slot = File.join(shared, name)
      touch(File.join(slot, "debug", "a"))
      File.write(File.join(slot, Hecks::RustBuild::SessionBuild::OWNER), owner) if owner
      back_date(slot, days)
      slot
    end

    def prune(listed = [], **options) = described_class.unlisted_slots(shared, listed, **options)

    it "keeps a slot whose recorded owner still exists" do
      slot = make_slot("other-clone-0123abcd", owner: dir)
      prune

      expect(File.directory?(slot)).to be(true)
    end

    it "removes a slot whose recorded owner is gone" do
      slot = make_slot("gone-owner-0123abcd", owner: File.join(dir, "no-such-tree"))
      prune

      expect(File.directory?(slot)).to be(false)
    end

    it "keeps a slot something changed in within the last day" do
      slot = make_slot("busy-0123abcd", days: 0)
      prune

      expect(File.directory?(slot)).to be(true)
    end

    # A checkout `main` with a worktree directory under `.claude/worktrees` that git does not list
    # (one removed by hand, leaving a `rust/target` behind): it still exists but is not a worktree.
    def main_with_leftover_worktree
      main = File.join(dir, "main")
      leftover = File.join(main, ".claude", "worktrees", "removed")
      FileUtils.mkdir_p([leftover, File.join(main, ".claude", "worktrees", "listed")])
      [main, leftover, File.join(main, ".claude", "worktrees", "listed")]
    end

    it "removes a slot whose recorded owner is a worktree directory git no longer lists", :aggregate_failures do
      main, leftover, = main_with_leftover_worktree
      slot = make_slot("leftover-0123abcd", owner: File.realpath(leftover))
      prune([main])

      expect(File.directory?(slot)).to be(false)
      expect(File.directory?(leftover)).to be(true)
    end

    it "keeps a slot whose recorded owner is a worktree directory git lists" do
      main, _, listed = main_with_leftover_worktree
      slot = make_slot("listed-0123abcd", owner: File.realpath(listed))
      prune([main, listed])

      expect(File.directory?(slot)).to be(true)
    end

    # A slot of an old date holding thirty recent files.
    def busy_slot
      slot = make_slot("many-0123abcd", days: 5)
      30.times { |n| touch(File.join(slot, "debug", "deps", "f#{n}"), age_days: 0) }
      File.utime(Time.now - (5 * 86_400), Time.now - (5 * 86_400), slot)
    end

    # The paths a prune looked at, one by one.
    def paths_looked_at
      looks = []
      allow(File).to(receive(:lstat).and_wrap_original { |original, *args| original.call(*args).tap { looks << args.first } })
      prune
      looks
    end

    def paths_looked_at_in_a_busy_slot
      busy_slot
      paths_looked_at
    end

    it "stops looking for recent work at the first thing that changed" do
      expect(paths_looked_at_in_a_busy_slot.size).to be < 15
    end

    it "keeps a slot it cannot read the contents of" do
      slot = make_slot("unreadable-0123abcd")
      allow(Find).to receive(:find).and_raise(Errno::EACCES)
      prune

      expect(File.directory?(slot)).to be(true)
    end

    # A worktree git lists as `link/real`, whose slot was named from the path the file system
    # spells.
    def listed_through_a_link
      real = File.join(dir, "trees", "real")
      FileUtils.mkdir_p(real)
      File.symlink(File.join(dir, "trees"), File.join(dir, "link"))
      [File.join(dir, "link", "real"), make_slot(Hecks::RustBuild::SessionBuild.slug(File.realpath(real)))]
    end

    it "keeps a slot git lists under the other spelling of its path" do
      listed, slot = listed_through_a_link
      prune([listed])

      expect(File.directory?(slot)).to be(true)
    end

    it "deletes nothing on a dry run" do
      slot = make_slot("dry-0123abcd")
      prune(dry_run: true)

      expect(File.directory?(slot)).to be(true)
    end
  end

  describe ".shared_targets" do
    it "names the shared directory and each directory in it" do
      FileUtils.mkdir_p([File.join(dir, "a-0123abcd"), File.join(dir, "codegen")])

      expect(described_class.shared_targets(dir)).to contain_exactly(dir, File.join(dir, "a-0123abcd"), File.join(dir, "codegen"))
    end

    it "reaches the artifacts of a worktree's own directory" do
      old = touch(File.join(dir, "a-0123abcd", "debug", "deps", "old.rlib"), age_days: 30)
      described_class.stale(described_class.shared_targets(dir), days: 14)

      expect(File.exist?(old)).to be(false)
    end
  end

  describe ".targets_of" do
    let!(:done) { touch(File.join(dir, "done", "rust", "host", "target", "a")) }
    let!(:open_one) { touch(File.join(dir, "open", "rust", "target", "a")) }

    it "removes the targets inside the worktrees it is given" do
      described_class.targets_of([File.join(dir, "done")])
      expect(File.exist?(done)).to be(false)
    end

    it "leaves the other worktrees' targets" do
      described_class.targets_of([File.join(dir, "done")])
      expect(File.exist?(open_one)).to be(true)
    end
  end

  describe ".orphans" do
    let!(:gone) { touch(File.join(dir, "gone", "rust", "target", "a")) }
    let!(:kept) { touch(File.join(dir, "kept", "rust", "target", "a")) }
    let(:live) { [File.join(dir, "kept")] }

    it "removes the target of a worktree git does not list" do
      described_class.orphans(dir, live: live)
      expect(File.exist?(gone)).to be(false)
    end

    it "keeps the target of a listed worktree" do
      described_class.orphans(dir, live: live)
      expect(File.exist?(kept)).to be(true)
    end
  end
end
