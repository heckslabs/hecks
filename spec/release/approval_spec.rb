require "spec_helper"
require "hecks/release/approval"

# A release is the owner's decision: the commit that set the version must say so in its message.
RSpec.describe Hecks::Release::Approval do
  let(:bump) { "Release 3.11.0: something\n\nBody.\n\nRelease-Approved-By: Christopher Young\n" }
  let(:plain) { "Release 3.11.0: something\n\nCo-Authored-By: Someone <a@b.c>\n" }

  it "takes its trailer from the Lane row a release is cut from" do
    row = Hecks::Vocabulary.rows("Lane").find { |lane| lane["name"] == "stable" }

    expect(described_class.trailer).to eq(row.fetch("release_trailer"))
  end

  describe ".approver" do
    it "names who approved, from the trailer line" do
      expect(described_class.approver(bump)).to eq("Christopher Young")
    end

    it "finds nothing in a message without the trailer, or with an empty one", :aggregate_failures do
      expect(described_class.approver(plain)).to be_nil
      expect(described_class.approver("x\n\nRelease-Approved-By:\n")).to be_nil
      expect(described_class.approver("Release-Approved-By-Not: me")).to be_nil
      expect(described_class.approver("says Release-Approved-By: me in prose")).to be_nil
    end
  end

  describe ".verdict" do
    it "accepts a bump commit that carries the trailer" do
      expect(described_class.verdict(message: bump).first).to be(true)
    end

    it "refuses a bump commit without it, and says what to do", :aggregate_failures do
      ok, words = described_class.verdict(message: plain)

      expect(ok).to be(false)
      expect(words).to include("Release-Approved-By: <name>", "Nothing was tagged", "approved_by=<name>")
    end

    it "accepts a release whose tag already stands, so a half-cut release can be finished" do
      expect(described_class.verdict(message: plain, tag_exists: true).first).to be(true)
    end

    it "accepts a by-hand approval from the owner, and ignores a blank one", :aggregate_failures do
      expect(described_class.verdict(message: plain, explicit: "Christopher").first).to be(true)
      expect(described_class.verdict(message: plain, explicit: "  ").first).to be(false)
    end
  end

  describe ".check" do
    def run(env) = [described_class.check(env: env, out: (out = StringIO.new)), out.string]

    it "exits 0 with the approver's name for an approved bump", :aggregate_failures do
      status, text = run("COMMIT_MESSAGE" => bump, "TAG_EXISTS" => "false")

      expect(status).to eq(0)
      expect(text).to include("approved by Christopher Young")
    end

    it "exits 1 with a workflow error line for an unapproved bump", :aggregate_failures do
      status, text = run("COMMIT_MESSAGE" => plain, "TAG_EXISTS" => "false")

      expect(status).to eq(1)
      expect(text).to start_with("::error::")
    end
  end
end
