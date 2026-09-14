require "spec_helper"

# Vocabulary::FieldHint (language/bluebook/vocabulary.bluebook) is the one
# table FieldShape's EMAIL_HINT/URL_HINT/TEL_HINT/TEXTAREA_HINT read
# (lib/hecks/forms/field_shape.rb builds them off the generated rows), and
# bin/project_field_hints writes rust/host/src/field_hints.rs from the same
# rows — so there is no hand copy left to hold equal. What stays here is
# the one fact text_field hard-codes about the declaration: which Field
# attribute each hint resolves to.
RSpec.describe "the declared field hints" do
  def self.meta = Hecks::Bluebook::MetaValidator.grammar_registry.bluebook("Bluebook")

  def self.declared_hints
    vocabulary = meta.aggregates.find { |a| a.hecks_name == "Vocabulary" }
    hint       = vocabulary.value_objects.find { |vo| vo.hecks_name == "FieldHint" }
    hint.members.map(&:to_h).to_h { |row| [row[:name], row] }
  end

  DECLARED_FIELD_HINTS = declared_hints

  it "resolves email/url/tel to html_type and textarea to kind — the two Field attributes text_field ever sets from a hint" do
    %w[email url tel].each { |name| expect(DECLARED_FIELD_HINTS[name][:resolves_to]).to eq("html_type") }
    expect(DECLARED_FIELD_HINTS["textarea"][:resolves_to]).to eq("kind")
  end
end
