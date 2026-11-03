require "spec_helper"
require "fileutils"
require "stringio"
require "tmpdir"
require "hecks/release/approval"
require "hecks/release/conditions"

# The auto-approval conditions of a release PR, and the trailer an approval writes for the owner.
RSpec.describe Hecks::Release::Conditions do
  let(:version) { "7.0.0" }
  let(:versions) { { "lib/hecks/version.rb" => version, "rust/host/HECKS_RELEASE" => version } }
  let(:changelog) { "## [Unreleased] - planned 7.0.0\n\n## [7.0.0] - 2026-11-02\n" }

  def judge(**overrides)
    described_class.judge(version: version, stable_head: true, checks_green: true,
                          changelog_dated: true, versions: versions, **overrides)
  end

  it "approves when every condition holds" do
    expect(judge).to eq("met")
  end

  it "names a commit that is not on stable's head", :aggregate_failures do
    expect(judge(stable_head: false)).to eq("not_on_stable_head")
  end

  it "names required checks that did not all pass" do
    expect(judge(checks_green: false)).to eq("checks_not_green")
  end

  it "names a CHANGELOG with no dated heading for the version" do
    expect(judge(changelog_dated: false)).to eq("changelog_undated")
  end

  it "names a version file that names another version" do
    expect(judge(versions: versions.merge("Gemfile.lock" => "6.0.0"))).to eq("version_mismatch")
  end

  it "names the first failing condition when several fail" do
    expect(judge(stable_head: false, checks_green: false)).to eq("not_on_stable_head")
  end

  it "finds a dated heading for the version and not a planned one", :aggregate_failures do
    expect(described_class.changelog_dated?(changelog, "7.0.0")).to be(true)
    expect(described_class.changelog_dated?(changelog, "7.0.1")).to be(false)
  end

  it "accepts the trailer an approval writes, with Chris Young as the approver", :aggregate_failures do
    message = "Release 7.0.0: the owner's bump\n\nRelease-Approved-By: Chris Young\n"

    expect(Hecks::Release::Approval.verdict(message: message).first).to be(true)
    expect(Hecks::Release::Approval.approver(message)).to eq("Chris Young")
  end

  # The ReleaseFile rows are the one list of version files; `unmet` holds a checkout against them.
  describe "against a checkout" do
    let(:root) { Dir.mktmpdir("hecks-release-files") }
    let(:version) { "9.9.9" }

    after { FileUtils.remove_entry(root) }

    def write(path, text)
      FileUtils.mkdir_p(File.dirname(File.join(root, path)))
      File.write(File.join(root, path), text)
    end

    def write_every_file
      write("lib/hecks/version.rb", %(module Hecks\n  VERSION = "#{version}".freeze\nend\n))
      write("CHANGELOG.md", "## [Unreleased]\n\n## [#{version}] - 2026-01-01\n")
      write("README.md", "**Status:** Current release: `#{version}`. See x\n")
      write("Gemfile.lock", "PATH\n    hecks (#{version})\n")
      write("rust/host/HECKS_RELEASE", "#{version}\n")
      %w[package.json package-lock.json].each do |file|
        write("packages/hecks-client/#{file}", %({\n  "name": "@hecks/client",\n  "version": "#{version}",\n}\n))
      end
    end

    it "finds nothing unmet when every ReleaseFile row names the version", :aggregate_failures do
      write_every_file

      expect(described_class.unmet(root, version)).to be_empty
      expect(described_class.check(root: root, out: StringIO.new)).to eq(0)
    end

    it "names the host release file when it is at another version" do
      write_every_file
      write("rust/host/HECKS_RELEASE", "9.9.8\n")

      expect(described_class.unmet(root, version).join).to include("rust/host/HECKS_RELEASE says \"9.9.8\"")
    end

    it "names a changelog heading that has no date", :aggregate_failures do
      write_every_file
      write("CHANGELOG.md", "## [#{version}]\n")
      out = StringIO.new

      expect(described_class.check(root: root, out: out)).to eq(1)
      expect(out.string).to start_with("::error::").and include("dated")
    end

    it "names a file that is missing" do
      write_every_file
      FileUtils.rm(File.join(root, "Gemfile.lock"))

      expect(described_class.unmet(root, version)).to include("Gemfile.lock is missing")
    end
  end
end
