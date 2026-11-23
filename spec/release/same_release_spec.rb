require "spec_helper"
require "tmpdir"
require "hecks/release/same_release"

# The 7.1.0 shape: the tag stands on the bump commit on the merged side, while the release commit
# a promotion finds is the merge. That tag is the release that exists, not a different one.
RSpec.describe Hecks::Release::SameRelease do
  def git(dir, *args) = system("git", "-C", dir, "-c", "user.name=t", "-c", "user.email=t@t", *args, out: File::NULL)

  def sha(dir, rev) = IO.popen(["git", "-C", dir, "rev-parse", rev], &:read).strip

  def bump(dir, version)
    FileUtils.mkdir_p(File.join(dir, "lib/hecks"))
    File.write(File.join(dir, "lib/hecks/version.rb"), "module Hecks\n  VERSION = \"#{version}\"\nend\n")
    git(dir, "add", "-A")
    git(dir, "commit", "-q", "-m", "Release #{version}")
  end

  def merged(dir)
    git(dir, "init", "-q", "-b", "main")
    bump(dir, "7.0.0")
    git(dir, "checkout", "-q", "-b", "release")
    bump(dir, "7.1.0")
    git(dir, "checkout", "-q", "main")
    File.write(File.join(dir, "other.txt"), "x")
    git(dir, "add", "-A")
    git(dir, "commit", "-q", "-m", "other work")
    git(dir, "merge", "-q", "--no-ff", "-m", "Merge release", "release")
  end

  def stands?(dir, tag, version = "7.1.0")
    described_class.stands?(tag_commit: sha(dir, tag), commit: sha(dir, "HEAD"), version: version, dir: dir)
  end

  around { |example| Dir.mktmpdir("same-release") { |dir| (@dir = dir) && merged(dir) && example.run } }

  it "counts a tag on the merged side that carries the same version as already released" do
    expect(stands?(@dir, "release")).to be(true)
  end

  it "does not count a tag on a commit that carries another version" do
    expect(stands?(@dir, "release~1")).to be(false)
  end

  it "does not count a tag on a commit the release does not contain" do
    git(@dir, "checkout", "-q", "-b", "elsewhere", "release~1")
    bump(@dir, "7.1.0")
    expect(described_class.stands?(tag_commit: sha(@dir, "elsewhere"), commit: sha(@dir, "main"),
                                   version: "7.1.0", dir: @dir)).to be(false)
  end
end
