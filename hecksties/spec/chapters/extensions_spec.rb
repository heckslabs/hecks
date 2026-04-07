# Extensions chapter self-description spec
#
# Verifies the Extensions chapter defines a domain with serve,
# persistence, and core extension aggregates.
#
require "spec_helper"
require "hecks/chapters/extensions"

RSpec.describe Hecks::Chapters::Extensions do
  subject(:domain) { described_class.definition }

  it "builds a domain named Extensions" do
    expect(domain.name).to eq("Extensions")
  end

  it "includes key aggregates" do
    names = domain.aggregates.map(&:name)
    expect(names).to include("Auth", "WebExplorer", "DomainServer", "FilesystemRepository")
  end

  it "has at least 25 aggregates" do
    expect(domain.aggregates.size).to be >= 25
  end

  it "gives every aggregate at least one command" do
    domain.aggregates.each do |agg|
      expect(agg.commands).not_to be_empty, "#{agg.name} has no commands"
    end
  end

  it "defines Authenticate and Authorize on Auth" do
    auth = domain.aggregates.find { |a| a.name == "Auth" }
    expect(auth.commands.map(&:name)).to include("Authenticate", "Authorize")
  end
end
