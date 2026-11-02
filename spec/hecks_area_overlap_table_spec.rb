require "spec_helper"
require "hecks/hecks/adapters/area_overlap"
require "tmpdir"

# The overlap rule must never miss a real overlap: every pair below that names ground in common
# must be true, in either order, and only provably disjoint pairs may be false.
RSpec.describe Hecks::Adapters::AreaOverlap do
  OVERLAPPING = [
    ["**/*.rb", "lib"], ["**/*.rb", "lib/**/*.rb"], ["*.rb", "lib/**/*.rb"], ["lib/*/x.rb", "lib/a"],
    ["lib/../spec", "spec/a.rb"], ["lib//hecks", "lib/hecks/a.rb"], ["lib/hecks/", "lib/hecks"],
    ["./lib", "lib/a"], ["", "lib/a"], ["", "**/*.rb"], ["lib/./hecks", "lib/hecks"],
    ["lib/a/../b", "lib/b/x"], ["lib/*/..", "lib/a/b.rb"], ["**", "x"], ["lib/**", "lib"],
    ["lib/{a,b/c}/x.rb", "lib/b/c"], ["lib/a*", "lib/ab*"], ["spec/**/*_spec.rb", "spec"],
    ["lib/?", "lib/a/b.rb"], ["lib/[ab]/x", "lib/a"], ["a/**/z", "a/b/c/z"], ["a/**/b/**/c", "a/b/c"]
  ].freeze

  DISJOINT = [
    ["lib/hecks", "lib/hecks_extra"], ["lib/a/*.rb", "lib/b"], ["lib/hecks/*.bluebook", "spec/x.bluebook"],
    ["lib/*.rb", "spec/*.rb"], ["lib/hecks/tickets", "lib/hecks/deliver"], ["lib/a*", "lib/b*"],
    ["lib/../spec", "lib/a.rb"], ["a/**/z", "b/y"]
  ].freeze

  OVERLAPPING.each do |one, other|
    it "overlaps #{one.inspect} and #{other.inspect}, in either order", :aggregate_failures do
      expect(described_class.overlap?(one, other)).to be(true)
      expect(described_class.overlap?(other, one)).to be(true)
    end
  end

  DISJOINT.each do |one, other|
    it "keeps #{one.inspect} apart from #{other.inspect}", :aggregate_failures do
      expect(described_class.overlap?(one, other)).to be(false)
      expect(described_class.overlap?(other, one)).to be(false)
    end
  end

  describe "a path known to be a file" do
    it "holds nothing beneath it", :aggregate_failures do
      expect(described_class.overlap?("lib/**/*.bluebook", "lib/a/x.rb", file: true)).to be(false)
      expect(described_class.overlap?("lib/**/*.bluebook", "lib/a/x.rb")).to be(true)
      expect(described_class.overlap?("lib/**/*.rb", "lib/a/x.rb", file: true)).to be(true)
      expect(described_class.overlap?("lib/a", "lib/a/x.rb", file: true)).to be(true)
      expect(described_class.overlap?("**/*.rb", "lib/a/x.rb", file: true)).to be(true)
    end
  end

  describe "absolute paths" do
    it "reads one inside the repository as repository-relative", :aggregate_failures do
      expect(described_class.overlap?("/repo/lib/a", "lib", root: "/repo")).to be(true)
      expect(described_class.overlap?("/repo/lib/a", "spec", root: "/repo")).to be(false)
    end

    it "keeps one outside the repository apart" do
      expect(described_class.overlap?("/elsewhere/lib", "lib", root: "/repo")).to be(false)
    end

    it "overlaps everything when the repository is unknown" do
      expect(described_class.overlap?("/anywhere/x", "spec")).to be(true)
    end
  end

  describe "case" do
    it "folds case on a filesystem that does" do
      Dir.mktmpdir("Area-Case") do |root|
        folds = File.exist?(root.swapcase)
        expect(described_class.overlap?("Lib/A", "lib/a", root: root)).to be(folds)
      end
    end
  end

  it "finds the first overlapping pair" do
    expect(described_class.first_overlap(%w[spec lib/a], %w[docs lib//a/x.rb])).to eq(["lib/a", "lib//a/x.rb"])
  end
end
