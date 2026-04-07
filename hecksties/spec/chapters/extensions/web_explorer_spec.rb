# Extensions::WebExplorerChapter paragraph spec
#
# Verifies web explorer internal aggregates exist within the Extensions domain.
#
require "spec_helper"
require "hecks/chapters/extensions"

RSpec.describe Hecks::Chapters::Extensions::WebExplorerChapter do
  subject(:domain) { Hecks::Chapters::Extensions.definition }

  it "includes IRIntrospector with Introspect command" do
    agg = domain.aggregates.find { |a| a.name == "IRIntrospector" }
    expect(agg).not_to be_nil
    expect(agg.commands.map(&:name)).to include("Introspect")
  end

  it "includes EventIntrospector with ListEvents command" do
    agg = domain.aggregates.find { |a| a.name == "EventIntrospector" }
    expect(agg).not_to be_nil
    expect(agg.commands.map(&:name)).to include("ListEvents")
  end

  it "includes Paginator with Paginate command" do
    agg = domain.aggregates.find { |a| a.name == "Paginator" }
    expect(agg).not_to be_nil
    expect(agg.commands.map(&:name)).to include("Paginate")
  end

  it "includes Renderer with Render command" do
    agg = domain.aggregates.find { |a| a.name == "Renderer" }
    expect(agg).not_to be_nil
    expect(agg.commands.map(&:name)).to include("Render")
  end

  it "includes RuntimeBridge with FindAll and ExecuteCommand commands" do
    agg = domain.aggregates.find { |a| a.name == "RuntimeBridge" }
    expect(agg).not_to be_nil
    expect(agg.commands.map(&:name)).to include("FindAll", "ExecuteCommand")
  end

  it "includes WebExplorerTemplateBinding with Bind command" do
    agg = domain.aggregates.find { |a| a.name == "WebExplorerTemplateBinding" }
    expect(agg).not_to be_nil
    expect(agg.commands.map(&:name)).to include("Bind")
  end
end
