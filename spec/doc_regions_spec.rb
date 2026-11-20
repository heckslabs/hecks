require "spec_helper"
require "hecks/doc/regions"

# The top-level pages' projected regions are read off the model: the bluebook map off the
# library's bluebooks and the route vocabulary off the Site bluebook's `Route` closed sets.
RSpec.describe Hecks::Doc::Regions do
  let(:root) { InMemoryDomain::ROOT }

  it "lists each library bluebook with its directory and vision" do
    expect(described_class::BluebookMap.render(root)).to include("- **Docs** (`lib/hecks/docs/`): A documentation page")
  end

  it "lists the Route closed sets with their members in declared order" do
    expect(described_class::RouteVocabulary.render(root))
      .to include("| `Kind` | `page`, `endpoint`, `redirect`, `rewrite`, `proxy` |")
  end
end
