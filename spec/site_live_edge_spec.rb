require "spec_helper"
require "hecks/tools"
require "hecks/tools/site_routes"
require "hecks/projections/site/live_edge"
require_relative "support/live_distribution"

# The comparison of a project's generated CloudFront behaviours with a live distribution's.
RSpec.describe Hecks::Projections::Site::LiveEdge do
  before(:all) do
    site = Hecks::Projections::Site
    registry = Hecks::Tools::SiteRoutes.registry_for(File.join(InMemoryDomain::ROOT, "spec/fixtures/site/studio"))
    chapter = site::Table.chapter(registry)
    table = site::Table.read(chapter, registry: registry)
    @edge = site::Edge.read(chapter, table: table, vocabulary: site::Table.vocabulary(registry))
  end

  let(:edge)  { @edge }
  let(:refs)  { LiveDistribution.refs_for(edge) }
  let(:live)  { LiveDistribution.for(edge, refs: refs) }
  let(:items) { live.dig("DistributionConfig", "CacheBehaviors", "Items") }

  def compare(config = live, **options) = described_class.new(edge, config, refs: refs, **options).call
  def behaviour(path) = items.find { |entry| entry["PathPattern"] == path }

  it "finds a live distribution built from the edge to match it" do
    comparison = compare

    expect(comparison).to be_clean
    expect(comparison.to_s).to end_with("the live distribution matches the project")
    expect(comparison.counts).to eq([edge.behaviours.size, edge.behaviours.size])
  end

  it "reads a configuration with or without the answer around it" do
    expect(compare(live.fetch("DistributionConfig"))).to be_clean
  end

  {
    "TargetOriginId"        => ["AssetsOrigin", "origin"],
    "ViewerProtocolPolicy"  => ["allow-all", "protocol"],
    "Compress"              => [true, "compress"],
    "CachePolicyId"         => ["11111111-1111-4111-8111-111111111111", "cache"],
    "OriginRequestPolicyId" => ["11111111-1111-4111-8111-111111111111", "request"]
  }.each do |key, (value, field)|
    it "names a behaviour that differs in #{field}" do
      behaviour("/api/*")[key] = value

      differences = compare.differences

      expect(differences.size).to eq(1)
      expect(differences.first).to start_with("/api/* differs in #{field}: project=")
    end
  end

  it "names a behaviour that differs in its methods" do
    behaviour("/robots.txt")["AllowedMethods"]["Items"] = %w[GET HEAD]

    expect(compare.differences).to eq(
      ["/robots.txt differs in methods: project=[\"GET\", \"HEAD\", \"OPTIONS\"] live=[\"GET\", \"HEAD\"]"]
    )
  end

  it "names a response policy the live behaviour lacks" do
    behaviour("/api/*").delete("ResponseHeadersPolicyId")

    expect(compare.differences.first).to start_with("/api/* differs in response: project=")
  end

  it "names the default behaviour as (default)" do
    live.dig("DistributionConfig", "DefaultCacheBehavior")["ViewerProtocolPolicy"] = "https-only"

    expect(compare.differences.first).to start_with("(default) differs in protocol:")
  end

  it "reports a behaviour only the project has, unless it was expected" do
    items.reject! { |entry| entry["PathPattern"] == "/pay/*" }

    expect(compare.differences).to match([start_with("only in the project: /pay/*")])
    expected = compare(expect_new: ["/pay/*"])
    expect(expected).to be_clean
    expect(expected.expected).to match([start_with("only in the project: /pay/*")])
    expect(expected.to_s).to include("expected additions")
  end

  it "reports a behaviour only the live distribution has, even when named as expected" do
    items << behaviour("/api/*").merge("PathPattern" => "/legacy/*")

    expect(compare(expect_new: ["/legacy/*"]).differences).to eq(["only live: /legacy/*"])
  end

  it "reports behaviours the two order differently" do
    items.rotate!

    differences = compare.differences

    expect(differences.size).to eq(1)
    expect(differences.first).to start_with("order differs among the behaviours both have:")
  end

  it "leaves a policy reference with no refs entry unchecked, which is not clean" do
    comparison = described_class.new(edge, live, refs: refs.except("!Ref SecurityHeaders")).call

    expect(comparison.unchecked).to eq(["!Ref SecurityHeaders"])
    expect(comparison).not_to be_clean
    expect(comparison.to_s).to include("no refs entry")
  end

  it "reads refs written as !Ref Name=id words" do
    expect(described_class.refs_from("!Ref A=1111, !Ref B=2222")).to eq("!Ref A" => "1111", "!Ref B" => "2222")
    expect(described_class.refs_from(nil)).to eq({})
  end
end
