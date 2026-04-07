# Extensions::AuthChapter paragraph spec
#
# Verifies auth internal aggregates exist within the Extensions domain.
#
require "spec_helper"
require "hecks/chapters/extensions"

RSpec.describe Hecks::Chapters::Extensions::AuthChapter do
  subject(:domain) { Hecks::Chapters::Extensions.definition }

  it "includes ScreenRoutes with HandleAuthRoute command" do
    agg = domain.aggregates.find { |a| a.name == "ScreenRoutes" }
    expect(agg).not_to be_nil
    expect(agg.commands.map(&:name)).to include("HandleAuthRoute")
  end

  it "includes SessionStore with SetSession and RestoreSession commands" do
    agg = domain.aggregates.find { |a| a.name == "SessionStore" }
    expect(agg).not_to be_nil
    expect(agg.commands.map(&:name)).to include("SetSession", "RestoreSession")
  end

  it "includes TemplateBinding with Bind command" do
    agg = domain.aggregates.find { |a| a.name == "TemplateBinding" }
    expect(agg).not_to be_nil
    expect(agg.commands.map(&:name)).to include("Bind")
  end
end
