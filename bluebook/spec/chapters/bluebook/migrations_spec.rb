require "spec_helper"
require "hecks/chapters/bluebook"

RSpec.describe Hecks::Chapters::Bluebook::MigrationsParagraph do
  subject(:domain) { Hecks::Chapters::Bluebook.definition }

  let(:names) { domain.aggregates.map(&:name) }

  it "includes migration aggregates" do
    expect(names).to include("DomainDiff", "BehaviorDiff",
                             "DomainSnapshot", "MigrationRunner")
  end

  it "DomainDiff has DiffDomains command" do
    agg = domain.aggregates.find { |a| a.name == "DomainDiff" }
    expect(agg.commands.map(&:name)).to include("DiffDomains")
  end

  it "DomainSnapshot has SaveSnapshot and LoadSnapshot commands" do
    agg = domain.aggregates.find { |a| a.name == "DomainSnapshot" }
    cmds = agg.commands.map(&:name)
    expect(cmds).to include("SaveSnapshot", "LoadSnapshot")
  end

  it "contributes at least 5 migration aggregates" do
    mig_names = %w[DomainDiff BehaviorDiff DomainSnapshot MigrationRunner MigrationStrategy]
    present = mig_names.select { |n| names.include?(n) }
    expect(present.size).to be >= 5
  end

  it "every migration aggregate has a description" do
    %w[DomainDiff BehaviorDiff DomainSnapshot MigrationRunner MigrationStrategy].each do |n|
      agg = domain.aggregates.find { |a| a.name == n }
      expect(agg.description).not_to be_nil, "#{n} missing description"
    end
  end
end
