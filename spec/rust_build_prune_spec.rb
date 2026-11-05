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

  it "removes only artifacts older than the cutoff and reports the bytes" do
    old = touch(File.join(dir, "debug", "deps", "old.rlib"), age_days: 30)
    fresh = touch(File.join(dir, "debug", "deps", "new.rlib"))
    expect(described_class.stale([dir], days: 14)).to eq(10)
    expect(File.exist?(old)).to be(false)
    expect(File.exist?(fresh)).to be(true)
  end

  it "leaves everything alone on a dry run" do
    old = touch(File.join(dir, "debug", "deps", "old.rlib"), age_days: 30)
    expect(described_class.stale([dir], days: 14, dry_run: true)).to eq(10)
    expect(File.exist?(old)).to be(true)
  end

  it "removes the target of a worktree git no longer lists" do
    gone = touch(File.join(dir, "gone", "rust", "target", "a"))
    kept = touch(File.join(dir, "kept", "rust", "target", "a"))
    expect(described_class.orphans(dir, live: [File.join(dir, "kept")])).to eq(10)
    expect(File.exist?(gone)).to be(false)
    expect(File.exist?(kept)).to be(true)
  end
end
