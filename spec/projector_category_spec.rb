require "spec_helper"

RSpec.describe Hecks::Projector do
  after { described_class.registry.delete(:stub) }

  # site_routes_ts reads options[:registry] but declares nothing, so by flags
  # alone it is a plain projection.
  EXPECTED_CATEGORIES = {
    projection: %i[cli command_schema diagrams docs glossary ir narrate oidc shape site_routes_ts statements],
    meta:       %i[bootstrap_table model parser_table reference rust_vocabulary vocabulary],
    export:     %i[aws_box aws_fargate aws_lambda]
  }.freeze

  describe ".category" do
    EXPECTED_CATEGORIES.each do |category, keys|
      keys.each do |key|
        it "puts #{key.inspect} in #{category.inspect}" do
          expect(described_class.category(key)).to eq(category)
        end
      end
    end

    it "calls an unregistered key a plain projection" do
      expect(described_class.category(:nonexistent)).to eq(:projection)
    end

    it "calls a target that answers no projection_category a plain projection" do
      described_class.register(:stub, Class.new { def self.call(bluebook:, options: {}) end })

      expect(described_class.category(:stub)).to eq(:projection)
    end

    def declaring_both
      Module.new do
        extend Hecks::Projector::Target

        projects_as :stub, declares: "Syntax", needs_world: true
      end
    end

    it "lets needs_world win over declares", :aggregate_failures do
      expect(declaring_both.projection_category).to eq(:export)
      expect(described_class.category(:stub)).to eq(:export)
    end
  end

  describe ".registered_by_category" do
    it "groups every registered key, sorted, under all three categories", :aggregate_failures do
      grouped = described_class.registered_by_category

      expect(grouped.keys).to eq(%i[projection meta export])
      EXPECTED_CATEGORIES.each { |category, keys| expect(grouped[category]).to include(*keys) }
      expect(grouped.values.flatten).to match_array(described_class.registered)
    end
  end

  it "names each category in the UnknownProjector message" do
    expect { described_class.call(:nonexistent, bluebook: nil) }
      .to raise_error(described_class::UnknownProjector, /projection \[.*\], meta \[.*\], export \[.*\]/)
  end
end
