require "spec_helper"
require "hecks/chapters/watchers"

RSpec.describe Hecks::Chapters::Watchers do
  subject(:domain) { described_class.definition }

  it "returns a Domain named Watchers" do
    expect(domain.name).to eq("Watchers")
  end

  it "includes all watcher aggregates" do
    names = domain.aggregates.map(&:name)
    expect(names).to include("WatcherRegistry", "FileSize", "CrossRequire",
                             "SpecCoverage", "DocReminder", "Runner",
                             "PreCommit", "Logger", "LogReader")
  end

  it "every aggregate has at least one command" do
    domain.aggregates.each do |agg|
      expect(agg.commands).not_to be_empty, "#{agg.name} has no commands"
    end
  end

  it "every aggregate has a description" do
    domain.aggregates.each do |agg|
      expect(agg.description).not_to be_nil, "#{agg.name} has no description"
    end
  end
end
