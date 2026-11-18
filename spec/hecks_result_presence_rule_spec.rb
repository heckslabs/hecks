require "spec_helper"

# A result type with a presence rule holds a pattern that no blank text meets, so a command
# handed a blank report is refused by the type rather than recorded as answered with nothing.
RSpec.describe "the presence rule on a command result" do
  around { |example| Hecks.with_registry(Hecks::Runtime::Registry.new) { example.run } }

  def rule
    bluebook = Hecks.bluebook("Probe") do
      aggregate "Run" do
        value_object("Key") { attribute :value, String, matches: :present }
        attribute :key, Key
        identified_by :key
      end
    end
    Regexp.new(bluebook.aggregates.first.value_objects.first.attributes.first.pattern)
  end

  it "is not met by a blank text" do
    expect(["", "  ", "\n"].grep(rule)).to be_empty
  end

  it "is met by a text that says something" do
    expect(rule.match?("it started the run")).to be(true)
  end
end
