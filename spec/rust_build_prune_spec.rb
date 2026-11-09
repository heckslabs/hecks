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
    let(:live_tree) { File.join(dir, "trees", "live") }
    let!(:live_slot) { touch(File.join(dir, "shared", Hecks::RustBuild::SessionBuild.slug(live_tree), "debug", "a")) }
    let!(:dead_slot) { touch(File.join(dir, "shared", "gone-0123abcd", "debug", "a")) }
    let!(:crate_dir) { touch(File.join(dir, "shared", "codegen", "debug", "a")) }

    before { described_class.unlisted_slots(File.join(dir, "shared"), [live_tree]) }

    it "removes the directory of a worktree git no longer lists" do
      expect(File.exist?(dead_slot)).to be(false)
    end

    it "keeps a listed worktree's directory and a crate's", :aggregate_failures do
      expect([File.exist?(live_slot), File.exist?(crate_dir)]).to eq([true, true])
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
