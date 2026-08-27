require "hecks"
require "hecks/ports/persistence/plugins/era"

# S2 (docs/audits/2026-08-10-main-bug-audit.md) — `dig_path` read
# `node[segment] || node[segment.to_sym]`, which drops a genuinely-stored
# `false` to `nil` (`false || …` falls through to the other key
# spelling — here, absent). `unfed` treats a `nil` dig as "nothing fed
# this attribute", so a boolean attribute a migration genuinely set to
# `false` was reported as unfed and steered toward a `default:` it does
# not need, on data that already carries a real, correct answer.
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
