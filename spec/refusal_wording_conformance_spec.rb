require "spec_helper"

# Every DomainRefusal wording that is not already data — `given`/`ensures`/a
# declared `invariant` already carry their own description, read at dispatch
# time. These are different in kind: LANGUAGE-LEVEL refusals, the same
# wording for every domain — closer to Vocabulary::Comparison/SignTest than
# to a given, so they follow THAT pattern: declared in
# language/bluebook/vocabulary.bluebook's `RefusalTemplate`, and a hand-typed
# table (RefusalWording) is what a dispatch actually reads. This is what
# holds the two equal, both directions — a template Ruby reads without
# declaring is the exact shape `role:` was for arguments ; a declared
# template Ruby never reads is dead vocabulary nobody would notice drifting.
RSpec.describe "the declared refusal wording" do
  def self.meta = Hecks::Bluebook::MetaValidator.grammar_registry.bluebook("Bluebook")

  def self.declared_templates
    vocabulary = meta.aggregates.find { |a| a.hecks_name == "Vocabulary" }
    template   = vocabulary.value_objects.find { |vo| vo.hecks_name == "RefusalTemplate" }
    template.members.map(&:to_h).to_h { |row| [[row[:refusal], row[:site]], row[:template]] }
  end

  REFUSAL_TEMPLATES_DECLARED = declared_templates

  REFUSAL_WORDING_RUBY_TABLE = Hecks::Runtime::RefusalWording::TEMPLATES
                               .to_h { |(refusal, site), template| [[refusal, site], template] }

  it "declares at least one template, so a language regression doesn't silently empty this" do
    expect(REFUSAL_TEMPLATES_DECLARED).not_to be_empty
  end

  it "reads at least one template from Ruby's own table" do
    expect(REFUSAL_WORDING_RUBY_TABLE).not_to be_empty
  end

  it "holds Ruby's table equal to the declared templates, both directions, wording included" do
    expect(REFUSAL_WORDING_RUBY_TABLE.keys.sort).to eq(REFUSAL_TEMPLATES_DECLARED.keys.sort),
                                                    "Ruby and the language disagree about which (refusal, site) pairs exist: " \
                                                    "#{(REFUSAL_WORDING_RUBY_TABLE.keys - REFUSAL_TEMPLATES_DECLARED.keys) +
                                                       (REFUSAL_TEMPLATES_DECLARED.keys - REFUSAL_WORDING_RUBY_TABLE.keys)}"

    REFUSAL_TEMPLATES_DECLARED.each do |key, template|
      expect(REFUSAL_WORDING_RUBY_TABLE[key]).to eq(template),
                                                 "#{key.inspect} reads #{REFUSAL_WORDING_RUBY_TABLE[key].inspect} in Ruby, " \
                                                 "which Vocabulary::RefusalTemplate declares as #{template.inspect}"
    end
  end
end
