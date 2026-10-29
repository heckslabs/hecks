require "spec_helper"
require "tmpdir"
require "hecks/release/approval"

# The 6.0.0 shape: a release branch whose bump commit carries the trailer, merged with a merge
# commit that does not. The owner's approval is read from the bump, not from the merge.
RSpec.describe Hecks::Release::VersionCommit do
  let(:approved) { "Release 6.0.0\n\nRelease-Approved-By: Chris Young\n" }
  let(:dir) { @dir }
  let(:unapproved) { "Release 6.0.0\n\nCo-Authored-By: Someone <a@b.c>\n" }

  def git(dir, *args) = system("git", "-C", dir, "-c", "user.name=t", "-c", "user.email=t@t", *args, out: File::NULL)

  def bump(dir, version, message)
    FileUtils.mkdir_p(File.join(dir, "lib/hecks"))
    File.write(File.join(dir, "lib/hecks/version.rb"), "module Hecks\n  VERSION = \"#{version}\"\nend\n")
    git(dir, "add", "-A")
    git(dir, "commit", "-q", "-m", message)
  end

  # A repository where main took `bump` on a side branch, merged with a merge commit.
  def merged_repo(dir, message)
    git(dir, "init", "-q", "-b", "main")
    bump(dir, "5.0.0", "Release 5.0.0\n\nRelease-Approved-By: Chris Young")
    git(dir, "checkout", "-q", "-b", "release")
    bump(dir, "6.0.0", message)
    git(dir, "checkout", "-q", "main")
    File.write(File.join(dir, "other.txt"), "x")
    git(dir, "add", "-A")
    git(dir, "commit", "-q", "-m", "other work")
    git(dir, "merge", "-q", "--no-ff", "-m", "Merge branch 'release'", "release")
  end

  def head(dir) = IO.popen(["git", "-C", dir, "rev-parse", "HEAD"], &:read).strip

  def judged(dir) = described_class.message(head(dir), dir: dir)

  def verdict(dir) = Hecks::Release::Approval.verdict(message: judged(dir)).first

  def plain_repo(dir)
    git(dir, "init", "-q", "-b", "main")
    bump(dir, "6.0.0", approved)
  end

  def check(dir, out) = Hecks::Release::Approval.check(env: { "COMMIT" => head(dir) }, out: out)

  around do |example|
    Dir.mktmpdir("release-lookup") { |dir| (@dir = dir) && example.run }
  end

  it "reads the approval from the bump on the merged side" do
    merged_repo(dir, approved)

    expect(verdict(dir)).to be(true)
  end

  it "refuses a merged bump that carries no trailer, whatever the merge says" do
    merged_repo(dir, unapproved)

    expect(verdict(dir)).to be(false)
  end

  it "judges a plain bump commit by its own message", :aggregate_failures do
    plain_repo(dir)

    expect(judged(dir)).to start_with("Release 6.0.0")
    expect(verdict(dir)).to be(true)
  end

  it "reaches the same verdict through Approval.check given the commit", :aggregate_failures do
    merged_repo(dir, approved)

    Dir.chdir(dir) { expect(check(dir, StringIO.new)).to eq(0) }
    expect(Hecks::Release::Approval.approver(judged(dir))).to eq("Chris Young")
  end
end
