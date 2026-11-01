require "hecks"
require "hecks/ports/persistence/plugins/era"
require_relative "../../../support/direct_chains"

# The head reads directly only on a chain the direct translation spec proved, keyed by the exact
# edges and the bluebook name. Needs no database. Regenerate the committed file with
# `HECKS_WRITE_DIRECT_VERIFIED=1` (see `Lineage::DirectVerified`).
RSpec.describe Hecks::Adapters::PostgresEra::Lineage::DirectVerified do
  DIRECT_HOST = Class.new { include Hecks::Adapters::PostgresEra::Lineage::DirectSql }
  PROVEN_CHAINS = DirectChains.chains

  File.write(described_class::PATH, described_class.render(PROVEN_CHAINS)) if ENV["HECKS_WRITE_DIRECT_VERIFIED"]

  def direct?(chain) = DIRECT_HOST.new.direct_translation?(edges_of(chain))

  def edges_of(chain) = chain.map { |edge| { translation: edge } }

  def renamed(edge, domain)
    Hecks::Bluebook::Translation.new(domain: domain, from: edge.from, to: edge.to, aggregates: edge.aggregates,
                                     retired: edge.retired)
  end

  def reruled(edge)
    extra = Hecks::Bluebook::TranslationAggregate.new(name: "Zebra", drops: [:stripes])
    Hecks::Bluebook::Translation.new(domain: edge.domain, from: edge.from, to: edge.to,
                                     aggregates: [*edge.aggregates, extra], retired: edge.retired)
  end

  it "holds exactly the fingerprints of the chains the repo proves" do
    expect(described_class.proven.sort).to eq(PROVEN_CHAINS.map { |*, chain| described_class.fingerprint(chain) }.uniq.sort)
  end

  PROVEN_CHAINS.each do |domain, start, final, chain|
    it "reads #{domain} #{start} to #{final} directly" do
      expect(direct?(chain)).to be(true)
    end

    it "reads a client chain named #{domain} with other rules through the chain" do
      other = chain.dup.tap { |edges| edges[-1] = reruled(edges.last) }
      expect(direct?(other)).to be(false)
    end

    it "reads the same edges under another bluebook name through the chain" do
      expect(direct?(chain.map { |edge| renamed(edge, "Client#{domain}") })).to be(false)
    end
  end

  it "reads an empty chain through the chain" do
    expect(direct?([])).to be(false)
  end
end
