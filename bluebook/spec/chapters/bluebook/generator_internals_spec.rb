require "spec_helper"
require "hecks/chapters/bluebook"

RSpec.describe Hecks::Chapters::Bluebook::GeneratorInternalsParagraph do
  subject(:domain) { Hecks::Chapters::Bluebook.definition }

  let(:names) { domain.aggregates.map(&:name) }

  it "includes generator internal aggregates" do
    expect(names).to include("Generator", "FileWriter", "SpecWriter",
                             "SkeletonGenerator", "SelfHostDiff")
  end

  it "FileWriter has WriteFile command" do
    agg = domain.aggregates.find { |a| a.name == "FileWriter" }
    expect(agg.commands.map(&:name)).to include("WriteFile")
  end

  it "contributes at least 10 generator internal aggregates" do
    gen_names = %w[Generator FileWriter SpecWriter LlmsTxtWriter SpecHelpers
                   InjectionHelpers FileLocator SkeletonGenerator SelfHostDiff
                   FrameworkGemGenerator]
    present = gen_names.select { |n| names.include?(n) }
    expect(present.size).to be >= 10
  end

  it "every generator internal aggregate has a description" do
    %w[Generator FileWriter SpecWriter SkeletonGenerator SelfHostDiff].each do |n|
      agg = domain.aggregates.find { |a| a.name == n }
      expect(agg.description).not_to be_nil, "#{n} missing description"
    end
  end
end
