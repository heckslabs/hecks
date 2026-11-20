require "spec_helper"
require "hecks/doc/pages"

# Every live documentation page, declared through the Docs bluebook and held to its regions'
# sources: README's generated regions, `docs/tools.md`'s tables, the top-level pages' marked
# regions, the CLI guides' command sections and the DSL reference projected from their generators,
# each page's prose held to what it mentions, and the guides' and reference's examples doctested by
# `spec/guides_spec.rb` and `spec/reference_doctest_spec.rb`.
RSpec.describe Hecks::Doc::Pages do
  let(:root) { InMemoryDomain::ROOT }

  it "declares README, the tools page, the reference and the guides as live pages" do
    expect(described_class.live(root).map { |page| page[:path] })
      .to include("README.md", "docs/tools.md", "docs/implemented/reference/aggregate.md",
                  "docs/implemented/guides/getting-started.md")
  end

  it "declares each CLI guide with its generated commands as a projected region" do
    deliver = described_class.live(root).find { |page| page[:path] == "docs/implemented/guides/cli/deliver.md" }
    expect(deliver[:regions].map { |region| region.values_at(:kind, :source) }).to include(%w[projected cli:deliver])
  end

  it "declares the architecture map, the site routes page and the decision index as live pages" do
    expect(described_class.live(root).map { |page| page[:path] })
      .to include("docs/architecture-map.md", "docs/site-routes.md", "docs/decisions/README.md")
  end

  it "declares the site routes page's closed sets as a region projected from the model" do
    routes = described_class.live(root).find { |page| page[:path] == "docs/site-routes.md" }
    expect(routes[:regions].map { |region| region.values_at(:kind, :source) })
      .to include(%w[projected region:route-vocabulary], ["prose", ""])
  end

  it "holds every projected region of this checkout to its source" do
    expect(described_class.drifts(root)).to be_empty
  end
end
