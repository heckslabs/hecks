# Extensions::ServeRoutesChapter paragraph spec
#
# Verifies serve route handler aggregates exist within the Extensions domain.
#
require "spec_helper"
require "hecks/chapters/extensions"

RSpec.describe Hecks::Chapters::Extensions::ServeRoutesChapter do
  subject(:domain) { Hecks::Chapters::Extensions.definition }

  it "includes RequestWrapper with Wrap command" do
    agg = domain.aggregates.find { |a| a.name == "RequestWrapper" }
    expect(agg).not_to be_nil
    expect(agg.commands.map(&:name)).to include("Wrap")
  end

  it "includes CorsHeaders with ApplyOrigin command" do
    agg = domain.aggregates.find { |a| a.name == "CorsHeaders" }
    expect(agg).not_to be_nil
    expect(agg.commands.map(&:name)).to include("ApplyOrigin")
  end

  it "includes CsrfHelpers with Validate and EnsureCookie commands" do
    agg = domain.aggregates.find { |a| a.name == "CsrfHelpers" }
    expect(agg).not_to be_nil
    expect(agg.commands.map(&:name)).to include("Validate", "EnsureCookie")
  end

  it "includes RouteDispatcher with Dispatch command" do
    agg = domain.aggregates.find { |a| a.name == "RouteDispatcher" }
    expect(agg).not_to be_nil
    expect(agg.commands.map(&:name)).to include("Dispatch")
  end

  it "includes IndexRoute with ServeIndex command" do
    agg = domain.aggregates.find { |a| a.name == "IndexRoute" }
    expect(agg).not_to be_nil
    expect(agg.commands.map(&:name)).to include("ServeIndex")
  end

  it "includes ShowRoute with ServeShow command" do
    agg = domain.aggregates.find { |a| a.name == "ShowRoute" }
    expect(agg).not_to be_nil
    expect(agg.commands.map(&:name)).to include("ServeShow")
  end

  it "includes FormRoute with ServeForm and ServeSubmit commands" do
    agg = domain.aggregates.find { |a| a.name == "FormRoute" }
    expect(agg).not_to be_nil
    expect(agg.commands.map(&:name)).to include("ServeForm", "ServeSubmit")
  end

  it "includes EventRoutes with ServeEvents command" do
    agg = domain.aggregates.find { |a| a.name == "EventRoutes" }
    expect(agg).not_to be_nil
    expect(agg.commands.map(&:name)).to include("ServeEvents")
  end

  it "includes UIRoutes with Mount command" do
    agg = domain.aggregates.find { |a| a.name == "UIRoutes" }
    expect(agg).not_to be_nil
    expect(agg.commands.map(&:name)).to include("Mount")
  end

  it "includes HttpConnection with Connect and Start commands" do
    agg = domain.aggregates.find { |a| a.name == "HttpConnection" }
    expect(agg).not_to be_nil
    expect(agg.commands.map(&:name)).to include("Connect", "Start")
  end
end
