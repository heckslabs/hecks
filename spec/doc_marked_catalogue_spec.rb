require "spec_helper"
require "hecks/doc/pages"

# A top-level page's regions are read from its own text in reading order, and a prose marker on
# one of them must name a heading of its page.
RSpec.describe Hecks::Doc::Pages::MarkedCatalogue do
  let(:root) { InMemoryDomain::ROOT }
  let(:check) { Hecks::Doc::ProseCheck.new(root, nil, headed: ["docs/tools.md"]) }
  let(:text) do
    "# Page\n\n<!-- prose anchor=\"Page\" purpose=\"concept\" -->\nWords.\n\n" \
      "<!-- generated:begin id=bluebooks -->\n<!-- generated:end -->\n" \
      "<!-- generated:begin tools section=Site -->\n<!-- generated:end tools -->\n"
  end

  # The prose region a marker with that anchor declares on the commands page.
  def prose(anchor)
    Hecks::Doc::ProseMarkers.read("docs/tools.md", "<!-- prose anchor=\"#{anchor}\" purpose=\"concept\" -->").first
  end

  it "reads a prose marker, a marked region and a tools table in reading order" do
    regions = described_class.new(root).regions("docs/page.md", text)
    expect(regions.drop(1).map(&:source)).to eq(%w[region:bluebooks tools:Site])
  end

  it "reads the prose marker as a prose region of its anchor" do
    expect(described_class.new(root).regions("docs/page.md", text).first.anchor).to eq("Page")
  end

  it "names a prose region whose anchor is no heading of its page" do
    expect(check.unheaded("docs/tools.md", prose("Gone"))).to eq(['names the heading "Gone", which the page lacks'])
  end

  it "passes a prose region whose anchor is a heading of its page" do
    expect(check.unheaded("docs/tools.md", prose("The commands"))).to be_empty
  end
end
