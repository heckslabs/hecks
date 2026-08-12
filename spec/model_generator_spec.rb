require "spec_helper"

# THE ANTI-DRIFT GATE for the generated model files — the same shape
# spec/parser_table_spec and spec/vocabulary_table_spec use: re-project
# in memory and refuse a diff, so a hand-edit to a generated holding half
# fails the ordinary suite rather than surviving until the next
# regeneration silently discards it.
RSpec.describe "the generated model" do
  let(:chapter) { Hecksagain::Bluebook::MetaValidator.grammar_registry.bluebook("Bluebook") }
  let(:projected) { Hecksagain::Projector.call(:model, bluebook: chapter) }

  Hecksagain::Projections::Model::HOST.each_value do |host|
    it "#{host.fetch(:file)} is exactly what bin/project_model would render" do
      committed = File.read(File.join(InMemoryDomain::ROOT, "lib/hecksagain/bluebook", host.fetch(:file)))

      expect(projected.fetch(host.fetch(:file))).to eq(committed),
        "lib/hecksagain/bluebook/#{host.fetch(:file)} has drifted — run bin/project_model"
    end
  end

  # THE PROPERTY THE SPLIT EXISTS FOR. A generated holding half is only
  # safe to overwrite because nothing survives in it that the language
  # cannot say — everything else is behind `settle` in Behaviour::X.
  it "renders only the holding half, never behaviour" do
    expect(projected.fetch("policy.rb")).to include("include Behaviour::Policy")
    expect(projected.fetch("policy.rb")).not_to match(/def (?!initialize)\w+/)
  end

  # A deviation's REASON is emitted from Deviations rather than typed into
  # the output, which is the only way a comment survives regeneration.
  it "carries the off-the-wire reason into the generated source" do
    expect(projected.fetch("policy.rb"))
      .to include("DELIBERATELY OFF THE WIRE", "the wire format is a pinned contract")
  end
end
