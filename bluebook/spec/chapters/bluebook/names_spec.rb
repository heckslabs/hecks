require "spec_helper"
require "hecks/chapters/bluebook"

RSpec.describe Hecks::Chapters::Bluebook::NamesParagraph do
  subject(:domain) { Hecks::Chapters::Bluebook.definition }

  let(:names) { domain.aggregates.map(&:name) }

  it "includes naming aggregates" do
    expect(names).to include("BaseName", "AggregateName", "CommandName", "EventName", "StateName")
  end

  it "BaseName has CreateName command" do
    agg = domain.aggregates.find { |a| a.name == "BaseName" }
    expect(agg.commands.map(&:name)).to include("CreateName")
  end

  it "contributes at least 5 naming aggregates" do
    naming = %w[BaseName AggregateName CommandName EventName StateName]
    present = naming.select { |n| names.include?(n) }
    expect(present.size).to be >= 5
  end

  it "every naming aggregate has a description" do
    %w[BaseName AggregateName CommandName].each do |n|
      agg = domain.aggregates.find { |a| a.name == n }
      expect(agg.description).not_to be_nil, "#{n} missing description"
    end
  end
end
