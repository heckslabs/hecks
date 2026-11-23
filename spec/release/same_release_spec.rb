require "spec_helper"
require "tmpdir"
require "hecks/release/same_release"

# The tag of a release may stand on the merged side of the merge commit that is the release
# commit: it is then the release that exists, not a different one.
RSpec.describe Hecks::Release::SameRelease do
  def git(dir, *args) = system("git", "-C", dir, "-c", "user.name=t", "-c", "user.email=t@t", *args, out: File::NULL)

  def sha(dir, rev) = IO.popen(["git", "-C", dir, "rev-parse", rev], &:read).strip

  def bump(dir, version)
    FileUtils.mkdir_p(File.join(dir, "lib/hecks"))
    File.write(File.join(dir, "lib/hecks/version.rb"), "module Hecks\n  VERSION = \"#{version}\"\nend\n")
    git(dir, "add", "-A")
    git(dir, "commit", "-q", "-m", "v#{version}")
  end

  def other(dir)
    File.write(File.join(dir, "other.txt"), SecureRandom.hex(4))
    git(dir, "add", "-A")
    git(dir, "commit", "-q", "-m", "other")
  end

  # main bumps 7.1.0 on a side branch (tagged there), then merges it with a merge commit.
  let(:dir) { @dir }
  let(:merged) { sha(dir, "HEAD") }
  let(:side) { sha(dir, "release") }

  around do |example|
    Dir.mktmpdir("same-release") do |dir|
      @dir = dir
      git(dir, "init", "-q", "-b", "main")
      bump(dir, "7.0.0")
      git(dir, "checkout", "-q", "-b", "release")
      bump(dir, "7.1.0")
      git(dir, "checkout", "-q", "main")
      other(dir)
      git(dir, "merge", "-q", "--no-ff", "-m", "Merge release", "release")
      example.run
    end
  end

  def stands?(tag, commit, version = "7.1.0") = described_class.stands?(tag_commit: tag, commit: commit, version: version, dir: dir)

  it "counts a tag on the merged side as the release that exists" do
    expect(stands?(side, merged)).to be(true)
  end

  it "counts a tag on the release commit itself" do
    expect(stands?(merged, merged)).to be(true)
  end

  it "does not count a tag whose tree holds another version" do
    expect(stands?(sha(dir, "main~1^2~1"), merged)).to be(false)
  end

  it "does not count a tag that is not an ancestor of the release commit", :aggregate_failures do
    git(dir, "checkout", "-q", "-b", "elsewhere", "main~1")
    bump(dir, "7.1.0")
    expect(stands?(sha(dir, "elsewhere"), merged)).to be(false)
  end

  it "does not count a tag git does not know" do
    expect(stands?("0" * 40, merged)).to be(false)
  end
end
