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
