require "spec_helper"
require "tmpdir"
require "fileutils"
require "json"
require "open3"
require "stringio"
require "hecks/tools"
require "hecks/tools/ci_gate_decision"

# A release bump inherits its base's certification (ADR 0107). The rule is data, the `ReleaseFile`
# and `RequiredCheck` rows; this spec pins how the rows are read: which diffs are a bump, when a
# base counts as certified, and what the CI gate answers for a real history.
RSpec.describe Hecks::Tools::ReleaseOnly do
  def only?(changes) = described_class.release_only?(changes)

  def run(name, conclusion, started = "2026-10-16T02:00:00Z")
    { "name" => name, "conclusion" => conclusion, "started_at" => started }
  end

  def every_inheritable_check(conclusion = "success")
    Hecks::Vocabulary.rows("RequiredCheck").reject { |row| row["runs"] == "always" }
                     .map { |row| run(row.fetch("name"), conclusion) }
  end

  describe ".release_only?" do
    it "admits a bump of the version files", :aggregate_failures do
      expect(only?("lib/hecks/version.rb" => ['  VERSION = "3.11.0".freeze'])).to be true
      expect(only?("rust/host/HECKS_RELEASE" => ["3.11.0"], "CHANGELOG.md" => ["any prose at all"])).to be true
    end

    it "refuses a change with a file that is not a release file" do
      expect(only?("lib/hecks/version.rb" => ['  VERSION = "3.11.0".freeze'], "lib/hecks/runtime.rb" => ["x"])).to be false
    end

    it "refuses a README line that is not a status line" do
      expect(only?("README.md" => ["Current release: `3.11.0`.", "A new claim about the product"])).to be false
    end

    it "refuses a Gemfile.lock line for another gem" do
      expect(only?("Gemfile.lock" => ["    hecks (3.11.0)", "    rack (3.2.0)"])).to be false
    end

    it "refuses a version.rb line that is not the version" do
      expect(only?("lib/hecks/version.rb" => ['  VERSION = "3.11.0".freeze', "  EVIL = system('x')"])).to be false
    end

    it "refuses an empty change" do
      expect(only?({})).to be false
    end
  end

  describe ".certified?" do
    it "accepts a base on which every inheritable check passed or was skipped" do
      runs = every_inheritable_check.tap { |all| all[0] = run(all[0]["name"], "skipped") }
      expect(described_class.certified?(runs)).to be true
    end

    it "does not ask a base for the check a bump still runs" do
      expect(described_class.certified?(every_inheritable_check)).to be true
    end

    it "refuses a base with one check failed" do
      runs = every_inheritable_check.tap { |all| all[1] = run(all[1]["name"], "failure") }
      expect(described_class.certified?(runs)).to be false
    end

    it "refuses a base with a check missing" do
      expect(described_class.certified?(every_inheritable_check.drop(1))).to be false
    end

    it "judges a check by its latest run" do
      first = every_inheritable_check.first
      reruns = [run(first["name"], "failure", "2026-10-16T01:00:00Z"), run(first["name"], "success", "2026-10-16T03:00:00Z")]
      expect(described_class.certified?(every_inheritable_check.drop(1) + reruns)).to be true
    end
  end

  describe ".parse" do
    let(:diff) do
      <<~DIFF
        diff --git a/Gemfile.lock b/Gemfile.lock
        --- a/Gemfile.lock
        +++ b/Gemfile.lock
        @@ -4 +4 @@
        -    hecks (3.10.0)
        +    hecks (3.11.0)
        diff --git a/README.md b/README.md
        --- a/README.md
        +++ b/README.md
        @@ -26 +26 @@
        -Current release: `3.10.0`
        +Current release: `3.11.0`
      DIFF
    end

    it "keys each changed line by its file, without the sign or the headers" do
      expect(described_class.parse(diff)).to eq(
        "Gemfile.lock" => ["    hecks (3.10.0)", "    hecks (3.11.0)"],
        "README.md"    => ["Current release: `3.10.0`", "Current release: `3.11.0`"]
      )
    end
  end

  describe "the rows" do
    it "name every file the release workflow's version spec reads", :aggregate_failures do
      paths = Hecks::Vocabulary.rows("ReleaseFile").map { |row| row["path"] }
      expect(paths).to include("lib/hecks/version.rb", "rust/host/HECKS_RELEASE", "CHANGELOG.md")
      expect(Hecks::Vocabulary.rows("RequiredCheck").map { |row| row["name"] }).to include("release_consistency")
    end

    it "mark exactly the consistency check as always run" do
      always = Hecks::Vocabulary.rows("RequiredCheck").select { |row| row["runs"] == "always" }
      expect(always.map { |row| row["name"] }).to eq(["release_consistency"])
    end
  end
end
