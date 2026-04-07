require "spec_helper"
require "hecks/chapters/bluebook"

RSpec.describe Hecks::Chapters::Bluebook::FeaturesParagraph do
  subject(:domain) { Hecks::Chapters::Bluebook.definition }

  let(:names) { domain.aggregates.map(&:name) }

  it "includes feature aggregates" do
    expect(names).to include("LeakySliceDetection", "ConnectionConfig")
  end

  it "LeakySliceDetection has DetectLeaks command" do
    agg = domain.aggregates.find { |a| a.name == "LeakySliceDetection" }
    expect(agg.commands.map(&:name)).to include("DetectLeaks")
  end

  it "ConnectionConfig has ConfigureConnection command" do
    agg = domain.aggregates.find { |a| a.name == "ConnectionConfig" }
    expect(agg.commands.map(&:name)).to include("ConfigureConnection")
  end

  it "contributes at least 2 feature aggregates" do
    feat_names = %w[LeakySliceDetection ConnectionConfig]
    present = feat_names.select { |n| names.include?(n) }
    expect(present.size).to be >= 2
  end

  it "every feature aggregate has a description" do
    %w[LeakySliceDetection ConnectionConfig].each do |n|
      agg = domain.aggregates.find { |a| a.name == n }
      expect(agg.description).not_to be_nil, "#{n} missing description"
    end
  end
end
