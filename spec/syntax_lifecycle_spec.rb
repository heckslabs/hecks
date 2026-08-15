
require "spec_helper"

# Every word of the bluebook surface now stands somewhere in its own
# life — the same proposed → admitted → retired shape the expression
# grammar's operators carry, plus `deprecated` (still read, on its way
# out). A row defaults to admitted, so the syntax table stays a table of
# words; only a word entering or leaving the language spells its status.
#
# (Constants here carry unique names on purpose: a constant assigned
# inside an RSpec.describe block lands at TOP LEVEL — the block captures
# its file's lexical scope — so a KEYWORDS here silently replaced
# syntax_conformance_spec's stringified KEYWORDS for every file loaded
# after it. Found as an order-dependent NoMethodError two files away.)
#
# What makes the status LOAD-BEARING rather than decorative is the
# projection rule this file pins: a proposed or retired word reaches no
# generated parser table, so to every projected reader such a word simply
# does not exist — the operator rule, applied at the syntax layer. The
# language also declares its own VERSION now, on the chapter itself,
# bumped when the admitted surface changes.
RSpec.describe "the syntax lifecycle" do
  def self.judged_meta = Hecksagain::Bluebook::MetaValidator.grammar_registry.bluebook("Bluebook")

  def self.syntax = judged_meta.aggregates.find { |a| a.hecks_name == "Syntax" }

  def self.rows(name)
    syntax.value_objects.find { |vo| vo.hecks_name == name }.members.map(&:to_h)
  end

  WORD_STATUSES  = rows("Status").map { |row| row[:name] }
  # S14, ADR 0026 — Keyword/Argument are genuine entities of Syntax now,
  # dispatched through a real lifecycle rather than merely declared —
  # `SyntaxBoot.call` reads them back post-dispatch, same shape `rows`
  # above still produces for Status (an ordinary closed set, unaffected).
  SYNTAX_TABLE  = Hecksagain::Bluebook::MetaValidator::SyntaxBoot.call
  WORD_ROWS     = SYNTAX_TABLE[:keywords]
  ARGUMENT_ROWS = SYNTAX_TABLE[:arguments]
  DECLARED_LANGUAGE_VERSION = judged_meta.version

  # AN ABSENT STATUS READS AS ADMITTED — the same convention hecks_eras
  # uses for a column grown after rows existed (canon_form NULL reads as
  # an implicit 1). Spelling `status: "admitted"` on 197 rows would bury
  # the table in ceremony, and applying the attribute DEFAULT to member
  # rows before export would hand the golden IR a field the source never
  # spells — a drift from the declared text bought for nothing. Only a
  # word entering or leaving the language spells its status.
  def self.status_of(row) = row[:status].to_s.empty? ? "admitted" : row[:status].to_s
  def status_of(row)      = self.class.status_of(row)

  it "declares the four stations of a word's life" do
    expect(WORD_STATUSES).to eq(%w[proposed admitted deprecated retired])
  end

  it "gives every keyword and argument a status the set admits" do
    (WORD_ROWS + ARGUMENT_ROWS).each do |row|
      expect(WORD_STATUSES).to include(status_of(row)),
                          "#{row[:word] || row[:keyword]} in #{row[:context]} carries " \
                          "status #{row[:status].inspect}, which the language does not admit"
    end
  end

  # ("Nothing mid-transition" was pinned here once — an empty-set gate on
  # any non-admitted row. bin/evolve made it wrong: a proposal must be able
  # to land green. Its job passed to syntax_conformance_spec's lifecycle
  # directions — a proposed word must be UNANSWERED by its builder, a
  # retired one must be unanswered again, and a live word is held to the
  # builder exactly as before. The suite still names every transition; it
  # just no longer forbids being in one.)

  it "reports no word as both visible and hidden — the projection rule, held over the rows themselves" do
    # No generated table exists to read back since the code-generating
    # projection was retired ; what's still checkable from the rows alone is that the
    # visible/hidden partition itself is well-formed — every word is one or
    # the other, never both, and every hidden word really is proposed or
    # retired rather than merely absent from a stale visible list.
    visible = WORD_ROWS.reject { |row| %w[proposed retired].include?(status_of(row)) }
                      .map { |row| row[:word] }
    hidden = WORD_ROWS.map { |row| row[:word] } - visible

    expect(visible & hidden).to be_empty

    hidden.each do |word|
      row = WORD_ROWS.find { |r| r[:word] == word }
      expect(%w[proposed retired]).to include(status_of(row)),
                                      "#{word} is hidden but its own status is #{status_of(row).inspect}"
    end
  end

  it "declares the language's own version" do
    expect(DECLARED_LANGUAGE_VERSION).to eq("1")
  end
end
