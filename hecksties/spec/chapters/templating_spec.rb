require "spec_helper"
require "hecks/chapters/templating"

RSpec.describe Hecks::Chapters::Templating do
  subject(:domain) { described_class.definition }

  it "returns a Domain named Templating" do
    expect(domain.name).to eq("Templating")
  end

  it "includes naming and smoke test aggregates" do
    names = domain.aggregates.map(&:name)
    expect(names).to include("NamingHelpers", "SmokeTest",
                             "FormSubmission", "EventChecks",
                             "BehaviorTests")
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
