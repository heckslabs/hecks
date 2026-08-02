
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
# generated parser table (bin/ir_syntax, bin/ir_syntax_flags,
# bin/ir_dispatch_words all reject them), so to every projected reader
# such a word simply does not exist — the operator rule, applied at the
# syntax layer. The language also declares its own VERSION now, on the
# chapter itself, bumped when the admitted surface changes.
RSpec.describe "the syntax lifecycle" do
  def self.judged_meta = Hecksagain::Bluebook::MetaValidator.grammar_registry.bluebook("Bluebook")

  def self.syntax = judged_meta.aggregates.find { |a| a.hecks_name == "Syntax" }

  def self.rows(name)
    syntax.value_objects.find { |vo| vo.hecks_name == name }.members.map(&:to_h)
  end

  WORD_STATUSES  = rows("Status").map { |row| row[:name] }
  WORD_ROWS  = rows("Keyword")
  ARGUMENT_ROWS = rows("Argument")
  DECLARED_LANGUAGE_VERSION = judged_meta.version

  # AN ABSENT STATUS READS AS ADMITTED — the same convention hecks_eras
  # uses for a column grown after rows existed (canon_form NULL reads as
  # an implicit 1). Spelling `status: "admitted"` on 197 rows would bury
  # the table in ceremony, and applying the attribute DEFAULT to member
  # rows on the Ruby side only would hand the golden IR a field Rust's
  # parser does not mint — an IR-parity split bought for nothing. Only a
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

  it "keeps every current word admitted — nothing is mid-transition" do
    # The day a word is proposed or deprecated, this example changes with
    # it, deliberately: a transition should be visible in the suite, not
    # only in the table.
    in_transition = (WORD_ROWS + ARGUMENT_ROWS).reject { |row| status_of(row) == "admitted" }
    expect(in_transition).to be_empty,
                             "words mid-transition: " \
                             "#{in_transition.map { |row| row[:word] || row[:keyword] }.inspect}"
  end

  it "projects no proposed or retired word into any generated table" do
    # The generators reject them at the source; this holds the rule from
    # the reading side by deriving what each table WOULD hold and
    # asserting the invisible statuses are absent from all of it.
    visible = WORD_ROWS.reject { |row| %w[proposed retired].include?(status_of(row)) }
                      .map { |row| row[:word] }
    hidden = WORD_ROWS.map { |row| row[:word] } - visible

    root = InMemoryDomain::ROOT
    projections = [
      `#{File.join(root, 'bin/ir_syntax')}`,
      `#{File.join(root, 'bin/ir_dispatch_words')}`
    ].join("\n")

    hidden.each do |word|
      expect(projections).not_to match(/"#{Regexp.escape(word)}"/),
                                 "#{word} is proposed or retired and still reaches a projection"
    end
  end

  it "declares the language's own version" do
    expect(DECLARED_LANGUAGE_VERSION).to eq("1")
  end
end
