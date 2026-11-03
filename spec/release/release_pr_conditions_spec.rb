require "spec_helper"
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
end
