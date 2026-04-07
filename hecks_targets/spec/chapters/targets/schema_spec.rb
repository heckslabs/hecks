# Targets::SchemaParagraph paragraph spec
#
# Verifies schema generator aggregates exist within the Targets domain.
#
require "spec_helper"
require "hecks/chapters/targets"

RSpec.describe Hecks::Chapters::Targets::SchemaParagraph do
  subject(:domain) { Hecks::Chapters::Targets.definition }

  it "includes TypescriptGenerator" do
    agg = domain.aggregates.find { |a| a.name == "TypescriptGenerator" }
    expect(agg).not_to be_nil
    expect(agg.commands.map(&:name)).to include("GenerateTypescript")
  end

  it "includes JsonSchemaGenerator" do
    agg = domain.aggregates.find { |a| a.name == "JsonSchemaGenerator" }
    expect(agg).not_to be_nil
    expect(agg.commands.map(&:name)).to include("GenerateJsonSchema")
  end

  it "includes OpenapiGenerator" do
    agg = domain.aggregates.find { |a| a.name == "OpenapiGenerator" }
    expect(agg).not_to be_nil
    expect(agg.commands.map(&:name)).to include("GenerateOpenapi")
  end

  it "includes RpcDiscovery" do
    agg = domain.aggregates.find { |a| a.name == "RpcDiscovery" }
    expect(agg).not_to be_nil
    expect(agg.commands.map(&:name)).to include("GenerateRpcDiscovery")
  end
end
