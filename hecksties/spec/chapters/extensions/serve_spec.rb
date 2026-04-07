# Extensions::ServeChapter paragraph spec
#
# Verifies serve-related aggregates exist within the Extensions domain.
#
require "spec_helper"
require "hecks/chapters/extensions"

RSpec.describe Hecks::Chapters::Extensions::ServeChapter do
  subject(:domain) { Hecks::Chapters::Extensions.definition }

  it "includes DomainServer with Start and Stop commands" do
    agg = domain.aggregates.find { |a| a.name == "DomainServer" }
    expect(agg).not_to be_nil
    expect(agg.commands.map(&:name)).to include("Start", "Stop")
  end

  it "includes MultiDomainServer" do
    agg = domain.aggregates.find { |a| a.name == "MultiDomainServer" }
    expect(agg).not_to be_nil
  end

  it "includes RpcServer" do
    agg = domain.aggregates.find { |a| a.name == "RpcServer" }
    expect(agg).not_to be_nil
  end

  it "includes RouteBuilder" do
    agg = domain.aggregates.find { |a| a.name == "RouteBuilder" }
    expect(agg).not_to be_nil
  end

  it "includes CommandBusPort with Dispatch command" do
    agg = domain.aggregates.find { |a| a.name == "CommandBusPort" }
    expect(agg.commands.map(&:name)).to include("Dispatch")
  end
end
