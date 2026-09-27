require "spec_helper"

# Every syntax word has a status (proposed, admitted, deprecated, retired); a proposed or
# retired word reaches no generated parser table.
RSpec.describe "the syntax lifecycle" do
  def self.judged_meta = Hecks::Bluebook::MetaValidator.grammar_registry.bluebook("Bluebook")

  def self.syntax = judged_meta.aggregates.find { |a| a.hecks_name == "Syntax" }

  def self.rows(name)
    syntax.value_objects.find { |vo| vo.hecks_name == name }.members.map(&:to_h)
  end

  WORD_STATUSES = rows("Status").map { |row| row[:name] }
  # Keyword and Argument are dispatched entities; `SyntaxBoot.call` reads them back post-dispatch.
  # Constant names are unique: one assigned in a describe block lands at top level and would
  # clobber syntax_conformance_spec's keywords.
  SYNTAX_TABLE  = Hecks::Bluebook::MetaValidator::SyntaxBoot.call
  WORD_ROWS     = SYNTAX_TABLE[:keywords]
  ARGUMENT_ROWS = SYNTAX_TABLE[:arguments]
  DECLARED_LANGUAGE_VERSION = judged_meta.version

  # An absent status reads as admitted, like a grown column in hecks_eras; spelling it on every row
  # would bury the table and hand the golden IR a field the source never spells.
  def self.status_of(row) = row[:status].to_s.empty? ? "admitted" : row[:status].to_s
  def status_of(row)      = self.class.status_of(row)

  it "declares the four stations of a word's life" do
    expect(WORD_STATUSES).to eq(%w[proposed admitted deprecated retired])
  end

  it "gives every keyword and argument a status the set admits" do
    (WORD_ROWS + ARGUMENT_ROWS).each do |row|
      expect(WORD_STATUSES).to include(status_of(row)),
                               "#{row.key?(:word) ? row[:word] : row[:keyword]} in #{row[:context]} carries " \
                               "status #{row[:status].inspect}, which the language does not admit"
    end
  end

  it "declares the language's own version" do
    expect(DECLARED_LANGUAGE_VERSION).to eq("1")
  end
end
