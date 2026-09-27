require "hecks"
require "hecks/ports/persistence/plugins/era"

# Pins that `dig_path` keeps a stored `false`; reading it as nil made `unfed` report
# a boolean the migration did set as unfed.
RSpec.describe "Audit.dig_path / .unfed — a stored false is a real, fed value" do
  describe ".dig_path" do
    it "reads a stored false leaf, string-keyed, rather than nil" do
      expect(Hecks::Translation::Audit.dig_path({ "active" => false }, "active")).to be(false)
    end

    it "reads a stored false leaf, symbol-keyed, rather than nil" do
      expect(Hecks::Translation::Audit.dig_path({ active: false }, "active")).to be(false)
    end

    it "reads a stored false leaf through a nested path" do
      expect(Hecks::Translation::Audit.dig_path({ "flags" => { "active" => false } }, "flags.active")).to be(false)
    end

    it "still reads a genuinely absent path as nil" do
      expect(Hecks::Translation::Audit.dig_path({ "other" => true }, "active")).to be_nil
    end
  end

  describe ".unfed" do
    UnfedReportFakeAttribute = Struct.new(:name, :default) unless defined?(UnfedReportFakeAttribute)
    UnfedReportFakeAggregate = Struct.new(:attributes) unless defined?(UnfedReportFakeAggregate)

    it "does not report a no-default boolean attribute genuinely stored as false" do
      aggregate = UnfedReportFakeAggregate.new([UnfedReportFakeAttribute.new(:active, nil)])
      after     = { "r1" => { "active" => false } }

      expect(Hecks::Translation::Audit.unfed(aggregate, nil, after)).to eq([])
    end

    it "still reports a no-default attribute nothing in the after-state carries" do
      aggregate = UnfedReportFakeAggregate.new([UnfedReportFakeAttribute.new(:active, nil)])
      after     = { "r1" => { "other" => true } }

      expect(Hecks::Translation::Audit.unfed(aggregate, nil, after)).to eq(["active"])
    end

    it "never reports an attribute that carries its own default" do
      aggregate = UnfedReportFakeAggregate.new([UnfedReportFakeAttribute.new(:active, false)])
      after     = { "r1" => { "other" => true } }

      expect(Hecks::Translation::Audit.unfed(aggregate, nil, after)).to eq([])
    end
  end
end
