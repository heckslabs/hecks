require "spec_helper"
require "hecks/forms/field_shape"

# Only what the bluebook declares is put into words; a rule this cannot read is quoted by its
# own description, never paraphrased.
RSpec.describe Hecks::Forms::FieldShape::RuleWords do
  def attribute(type, pattern: nil) = Hecks::Bluebook::Attribute.new(name: :value, type: type, pattern: pattern)

  def rule(canonical, description = "a rule") = Hecks::Bluebook::Invariant.new(description: description, canonical: canonical)

  def describe_number(type, canonical) = described_class.describe(attribute(type), [rule(canonical)])

  it "reads a named pattern and a blank check as one sentence" do
    present = Hecks::Bluebook::NamedPattern.source(:present)
    expect(described_class.describe(attribute("String", pattern: present), [rule("!value.to_s.strip.empty?")]))
      .to eq("Must not be blank.")
  end

  it "reads comparisons against a number as bounds", :aggregate_failures do
    expect(describe_number("Integer", "value.positive?")).to eq("A whole number above zero.")
    expect(describe_number("Integer", "value >= 0")).to eq("A whole number, zero or more.")
    expect(describe_number("Float", "value <= 10")).to eq("A number, 10 or less.")
  end

  it "quotes a rule it cannot read by its declared description" do
    expect(described_class.describe(attribute("String"), [rule("value.start_with?(\"A\")", "starts with A")]))
      .to eq("Rule: starts with A.")
  end

  it "says nothing for an unconstrained string or a raw regex" do
    expect(described_class.describe(attribute("String", pattern: "^x+$"))).to be_nil
  end
end
