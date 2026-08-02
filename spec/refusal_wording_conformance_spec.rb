
require "spec_helper"

# Every DomainRefusal wording that is not already data — `given`/`ensures`/a
# declared `invariant` already carry their own description, read at dispatch
# time. These are different in kind: LANGUAGE-LEVEL refusals, the same
# wording for every domain — closer to Vocabulary::Comparison/SignTest than
# to a given, so they follow THAT pattern: declared in
# language/bluebook/vocabulary.bluebook's `RefusalTemplate`, and a hand-typed
# table in each runtime (RefusalWording, Ruby ; refusal_wording.rs, Rust)
# is what a dispatch actually reads. This is what holds the three equal, both
# directions — a template one runtime reads without declaring is the exact
# shape `role:` was for arguments ; a declared template neither runtime reads
# is dead vocabulary nobody would notice drifting.
RSpec.describe "the declared refusal wording" do
  def self.meta = Hecksagain::Bluebook::MetaValidator.grammar_registry.bluebook("Bluebook")

  def self.declared_templates
    vocabulary = meta.aggregates.find { |a| a.hecks_name == "Vocabulary" }
    template   = vocabulary.value_objects.find { |vo| vo.hecks_name == "RefusalTemplate" }
    template.members.map(&:to_h).to_h { |row| [[row[:refusal], row[:site]], row[:template]] }
  end

  REFUSAL_TEMPLATES_DECLARED = declared_templates

  REFUSAL_WORDING_RUBY_TABLE = Hecksagain::Runtime::RefusalWording::TEMPLATES
                 .to_h { |(refusal, site), template| [[refusal, site], template] }

  # Read as TEXT, not executed — the same technique rust_syntax_conformance_
  # spec already uses to hold a Rust source file to a declaration.
  def self.rust_table
    source = File.read(File.join(InMemoryDomain::ROOT, "rust/src/runtime/refusal_wording.rs"))
    source.scan(/\(\s*"([A-Za-z]+)",\s*"([a-z_]+)",\s*"((?:[^"\\]|\\.)*)"\s*,?\s*\)/m).to_h do |refusal, site, text|
      [[refusal, site], text]
    end
  end

  REFUSAL_WORDING_RUST_TABLE = rust_table

  it "declares at least one template, so a language regression doesn't silently empty this" do
    expect(REFUSAL_TEMPLATES_DECLARED).not_to be_empty
  end

  it "reads at least one template from each runtime's own table" do
    expect(REFUSAL_WORDING_RUBY_TABLE).not_to be_empty
    expect(REFUSAL_WORDING_RUST_TABLE).not_to be_empty
  end

  it "holds Ruby's table equal to the declared templates, both directions, wording included" do
    expect(REFUSAL_WORDING_RUBY_TABLE.keys.sort).to eq(REFUSAL_TEMPLATES_DECLARED.keys.sort),
                                    "Ruby and the language disagree about which (refusal, site) pairs exist: " \
                                    "#{(REFUSAL_WORDING_RUBY_TABLE.keys - REFUSAL_TEMPLATES_DECLARED.keys) + (REFUSAL_TEMPLATES_DECLARED.keys - REFUSAL_WORDING_RUBY_TABLE.keys)}"

    REFUSAL_TEMPLATES_DECLARED.each do |key, template|
      expect(REFUSAL_WORDING_RUBY_TABLE[key]).to eq(template), "#{key.inspect} reads #{REFUSAL_WORDING_RUBY_TABLE[key].inspect} in Ruby, " \
                                               "which Vocabulary::RefusalTemplate declares as #{template.inspect}"
    end
  end

  # Rust has no caller for two templates at all — `Value.scalar`/
  # `Value.from_identifier` have no Rust equivalent, a pre-existing
  # asymmetry named rather than papered over (see refusal_wording.rs's own
  # header). Every OTHER declared template must still be there, wording
  # byte-identical, since bin/parity diffs it character for character.
  REFUSAL_WORDING_RUST_UNIMPLEMENTED = [%w[TypeMismatch multi_field_scalar], %w[TypeMismatch composite_identity]].freeze

  it "holds Rust's table equal to the declared templates it implements, wording included" do
    expected = REFUSAL_TEMPLATES_DECLARED.keys - REFUSAL_WORDING_RUST_UNIMPLEMENTED

    expect(REFUSAL_WORDING_RUST_TABLE.keys.sort).to eq((expected + REFUSAL_WORDING_RUST_UNIMPLEMENTED).sort),
                                    "Rust's table and the language disagree about which (refusal, site) " \
                                    "pairs exist: #{(REFUSAL_WORDING_RUST_TABLE.keys - REFUSAL_TEMPLATES_DECLARED.keys) + (REFUSAL_TEMPLATES_DECLARED.keys - REFUSAL_WORDING_RUST_TABLE.keys)}"

    REFUSAL_TEMPLATES_DECLARED.each do |key, template|
      expect(REFUSAL_WORDING_RUST_TABLE[key]).to eq(template), "#{key.inspect} reads #{REFUSAL_WORDING_RUST_TABLE[key].inspect} in Rust, " \
                                               "which Vocabulary::RefusalTemplate declares as #{template.inspect}"
    end
  end
end
