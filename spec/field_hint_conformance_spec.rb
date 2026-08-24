require "spec_helper"
require "hecks/forms/field_shape"

# FieldShape's own EMAIL_HINT/URL_HINT/TEL_HINT/TEXTAREA_HINT
# (lib/hecks/forms/field_shape.rb) are the LIVE table
# `text_field` reads at dispatch time — the same split RefusalTemplate/
# RefusalWording already established (refusal_wording_conformance_spec.rb):
# declared once, in language/bluebook/vocabulary.bluebook's `FieldHint`,
# for a human and a Rust codegen script (bin/project_field_hints) to
# read, and held equal to a hand-typed Ruby table here — both directions,
# wording (pattern source) included, so neither side can drift without
# this failing.
RSpec.describe "the declared field hints" do
  def self.meta = Hecks::Bluebook::MetaValidator.grammar_registry.bluebook("Bluebook")

  def self.declared_hints
    vocabulary = meta.aggregates.find { |a| a.hecks_name == "Vocabulary" }
    hint       = vocabulary.value_objects.find { |vo| vo.hecks_name == "FieldHint" }
    hint.members.map(&:to_h).to_h { |row| [row[:name], row] }
  end

  DECLARED_FIELD_HINTS = declared_hints

  # `Regexp#source` — the SAME reading bin/project_field_hints does to
  # write rust/host/src/field_hints.rs, so this spec and that generator
  # agree about what "the pattern" even means for a Ruby Regexp.
  FIELD_HINT_RUBY_TABLE = {
    "email"    => Hecks::Forms::FieldShape::EMAIL_HINT,
    "url"      => Hecks::Forms::FieldShape::URL_HINT,
    "tel"      => Hecks::Forms::FieldShape::TEL_HINT,
    "textarea" => Hecks::Forms::FieldShape::TEXTAREA_HINT,
  }.freeze

  it "declares at least one hint, so a language regression doesn't silently empty this" do
    expect(DECLARED_FIELD_HINTS).not_to be_empty
  end

  it "reads at least one hint from Ruby's own table" do
    expect(FIELD_HINT_RUBY_TABLE).not_to be_empty
  end

  it "holds Ruby's table equal to the declared hints, both directions, pattern source included" do
    expect(FIELD_HINT_RUBY_TABLE.keys.sort).to eq(DECLARED_FIELD_HINTS.keys.sort),
                                               "Ruby and the language disagree about which hint names exist: " \
                                               "#{(FIELD_HINT_RUBY_TABLE.keys - DECLARED_FIELD_HINTS.keys) + (DECLARED_FIELD_HINTS.keys - FIELD_HINT_RUBY_TABLE.keys)}"

    DECLARED_FIELD_HINTS.each do |name, row|
      expect(FIELD_HINT_RUBY_TABLE[name].source).to eq(row[:pattern]),
                                                    "#{name.inspect} reads #{FIELD_HINT_RUBY_TABLE[name].source.inspect} in Ruby, " \
                                                    "which Vocabulary::FieldHint declares as #{row[:pattern].inspect}"
    end
  end

  it "resolves email/url/tel to html_type and textarea to kind — the two Field attributes text_field ever sets from a hint" do
    %w[email url tel].each { |name| expect(DECLARED_FIELD_HINTS[name][:resolves_to]).to eq("html_type") }
    expect(DECLARED_FIELD_HINTS["textarea"][:resolves_to]).to eq("kind")
  end
end
