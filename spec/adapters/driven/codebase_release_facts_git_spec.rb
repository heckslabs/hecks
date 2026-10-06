require "spec_helper"
require "fileutils"
require "json"
require "open3"
require "tmpdir"
require "hecks/hecks/adapters/codebase/source_tree"

# The release facts read from real git: a clone of a local bare repository, never a network remote.
RSpec.describe Hecks::Adapters::Codebase::ReleaseFacts, :io do
  let(:scratch) { Dir.mktmpdir("hecks-release-git") }
  let(:origin) { File.join(scratch, "origin.git") }
  let(:work) { File.join(scratch, "work") }
  let(:identity) do
    { "GIT_AUTHOR_NAME" => "A", "GIT_AUTHOR_EMAIL" => "a@example.test",
      "GIT_COMMITTER_NAME" => "A", "GIT_COMMITTER_EMAIL" => "a@example.test" }
  end
  let(:facts) do
    described_class.new(Hecks::Adapters::Codebase::Tree.new(root: work), commands: Hecks::Release::Runner::Commands.new)
  end

  def git(*args, dir: work)
    out, err, status = Open3.capture3(identity, "git", *args, chdir: dir)
    raise "git #{args.join(" ")} failed: #{err}" unless status.success?

    out.strip
  end

  before do
    git("init", "-q", "--bare", "-b", "stable", origin, dir: scratch)
    git("clone", "-q", origin, work, dir: scratch)
    git("checkout", "-q", "-b", "stable")
    FileUtils.mkdir_p(File.join(work, "lib/hecks"))
    FileUtils.mkdir_p(File.join(work, "packages/hecks-client"))
    File.write(File.join(work, "lib/hecks/version.rb"), %(module Hecks\n  VERSION = "9.9.9".freeze\nend\n))
    File.write(File.join(work, "packages/hecks-client/package.json"), JSON.generate("version" => "9.9.9"))
    File.write(File.join(work, "CHANGELOG.md"), "## [9.9.9] - 2026-01-01\n")
    git("add", ".")
    git("commit", "-q", "-m", "release")
    git("push", "-q", "origin", "stable")
  end

  after { FileUtils.remove_entry(scratch) }

  it "finds a clean release lane equal to its origin with no tag" do
    found = facts.gather("publish")

    expect(found).to include(branch: { value: "stable" }, on_origin: { value: true }, clean: { value: true },
                             tag_state: { value: "none" }, head: { value: git("rev-parse", "HEAD") })
  end

  it "finds an untracked file, and a tag at the release commit" do
    File.write(File.join(work, "notes.txt"), "x")
    git("tag", "-a", "v9.9.9", "-m", "Release 9.9.9")

    expect(facts.gather("publish")).to include(clean: { value: false }, tag_state: { value: "at_release_commit" })
  end

  it "finds an unpushed commit, and a tag left behind at an earlier commit" do
    git("tag", "-a", "v9.9.9", "-m", "Release 9.9.9")
    File.write(File.join(work, "more.txt"), "y")
    git("add", ".")
    git("commit", "-q", "-m", "more")

    expect(facts.gather("publish")).to include(on_origin: { value: false }, tag_state: { value: "elsewhere" })
  end
end
