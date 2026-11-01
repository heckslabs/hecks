require "spec_helper"
require "hecks/hecks/adapters/area_overlap"

# The one rule for when two file areas overlap: whole-segment prefix containment either way, a
# glob against a prefix or its parent directories, and the literal stems of two globs.
RSpec.describe Hecks::Adapters::AreaOverlap do
  def overlap?(one, other) = described_class.overlap?(one, other)

  it "overlaps equal prefixes" do
    expect(overlap?("lib/hecks/tickets", "lib/hecks/tickets/")).to be(true)
  end

  it "overlaps a prefix and a path under it, in either order", :aggregate_failures do
    expect(overlap?("lib/hecks", "lib/hecks/tickets/a.rb")).to be(true)
    expect(overlap?("lib/hecks/tickets/a.rb", "./lib/hecks")).to be(true)
  end

  it "compares whole segments, not characters" do
    expect(overlap?("lib/hecks", "lib/hecks_extra")).to be(false)
  end

  it "keeps siblings apart" do
    expect(overlap?("lib/hecks/tickets", "lib/hecks/deliver")).to be(false)
  end

  it "overlaps a glob and a file it matches", :aggregate_failures do
    expect(overlap?("lib/**/*.bluebook", "lib/hecks/tickets/tickets.bluebook")).to be(true)
    expect(overlap?("lib/**/*.bluebook", "lib/hecks/tickets/tickets.rb")).to be(false)
  end

  it "overlaps a glob and a directory it matches, or one above its stem", :aggregate_failures do
    expect(overlap?("lib/*", "lib/hecks/a.rb")).to be(true)
    expect(overlap?("lib", "lib/a/*.rb")).to be(true)
  end

  it "keeps a glob apart from a sibling directory" do
    expect(overlap?("lib/a/*.rb", "lib/b")).to be(false)
  end

  it "overlaps two globs when one stem holds the other", :aggregate_failures do
    expect(overlap?("lib/**/*.rb", "lib/hecks/*.bluebook")).to be(true)
    expect(overlap?("lib/a/*.rb", "spec/**")).to be(false)
  end

  it "names the first overlapping pair" do
    expect(described_class.first_overlap(%w[spec lib/a], %w[docs lib/a/b.rb])).to eq(%w[lib/a lib/a/b.rb])
  end
end
