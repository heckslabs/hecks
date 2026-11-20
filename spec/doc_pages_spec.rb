require "spec_helper"
require "hecks/doc/pages"

# Every live documentation page, declared through the Docs bluebook and held to its regions'
# sources: README's generated regions, `docs/tools.md`'s tables and the DSL reference projected
# from their generators, and the guides' and reference's examples doctested by
# `spec/guides_spec.rb` and `spec/reference_doctest_spec.rb`.
RSpec.describe Hecks::Doc::Pages do
  let(:root) { InMemoryDomain::ROOT }

  it "declares README, the tools page, the reference and the guides as live pages" do
    expect(described_class.live(root).map { |page| page[:path] })
      .to include("README.md", "docs/tools.md", "docs/implemented/reference/aggregate.md",
                  "docs/implemented/guides/getting-started.md")
  end

  it "holds every projected region of this checkout to its source" do
    expect(described_class.drifts(root)).to be_empty
  end
end
