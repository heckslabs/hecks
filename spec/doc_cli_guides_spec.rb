require "spec_helper"
require "hecks/doc/pages"

# The CLI guides' prose: each marker becomes a Prose region with its mentions and supports, a marker
# whose kind the Docs bluebook does not allow is refused naming its page, and a mention that no
# longer resolves puts the region up for review through `Prose.FlagForReview`.
RSpec.describe Hecks::Doc::ProseMarkers do
  let(:path) { "docs/implemented/guides/cli/deliver.md" }
  let(:marker) { %(<!-- prose anchor="Concept" purpose="concept" mentions="command:Landing.land!" -->\n) }
  let(:layout) { Struct.new(:calls, :aggregates).new(Set["Shipment.ship!"], Set["Shipment"]) }

  it "reads a marker as a Prose region whose mentions are typed" do
    expect(described_class.read(path, marker).first.mentions).to eq([["command", "Landing.land!"]])
  end

  it "refuses a mention kind the Docs bluebook does not allow, naming the page" do
    expect { described_class.read(path, marker.sub("command:", "verse:")) }
      .to raise_error(ArgumentError, /\A#{Regexp.escape(path)}: prose "Concept" has kind "verse"/)
  end

  it "says which mention no longer resolves" do
    region = described_class.read(path, marker).first
    expect(Hecks::Doc::ProseCheck.new(InMemoryDomain::ROOT, layout).unresolved(region))
      .to eq(["mentions command Landing.land!, which the model no longer has"])
  end

  # A Memory boot of Docs with one page declared, whose prose is reviewed against `layout`.
  def review_of(page)
    runtime = Hecks.boot(Hecks::Doc::Pages::DOMAIN, environment: nil)
    Hecks::Doc::Pages.declare(runtime, page)
    Hecks::Doc::Pages::ProseReview.new(runtime, Hecks::Doc::ProseCheck.new(InMemoryDomain::ROOT, layout))
  end

  it "puts a region whose mention no longer resolves up for review" do
    page = Hecks::Doc::Pages::Catalogue::Entry.new(path, "deliver", described_class.read(path, marker))
    expect(review_of(page).drifts([page])).to eq(["#{path}#Concept: mentions command Landing.land!, which " \
                                                  "the model no longer has; revise the prose and its marker"])
  end
end
