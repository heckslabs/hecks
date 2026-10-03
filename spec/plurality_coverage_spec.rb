require "spec_helper"
require "json"

# Every list the language declares must hold two or more members somewhere in the corpus.
# A list only ever filled with one is indistinguishable from a scalar, which hid `identified_by`.
RSpec.describe "every list the language declares, filled more than once" do
  # Fields `contracts.rb` declares derived never reach the wire, so they cannot be counted there.
  def derived?(category, field)
    contract = Hecks::Bluebook::Assembly.contract(category)
    contract.derived.key?(field)
  rescue KeyError
    false
  end

  # Where the language and the wire disagree about a name. Must stay empty: an entry is a
  # defect with a workaround, not a design.
  WIRE_SPELLING = {}.freeze

  # Lists the corpus never fills twice. Each entry says why it is untested; delete one and the
  # spec tells you whether the corpus now covers it.
  ALLOWED_SINGLETON = {
    # Filled with two in lib/hecks/language/bluebook/attaches/paging.bluebook, a grammar
    # chapter with no golden IR fixture, so this walk cannot see it.
    "attaches_to" =>
                     "Paging attaches to two real contexts, \"Query\" and \"ReadModel\" — " \
                     "no golden IR fixture reaches it because Paging is a grammar " \
                     "chapter, not a frozen corpus member.",
    # Filled with three in lib/hecks/framework/bluebook/governance.bluebook (`provides
    # "authorization"`), a framework member with no golden IR fixture.
    "provides"    =>
                     "Governance provides authorization with three rows (assignments, grant, " \
                     "transitions) — a framework member, so no golden IR fixture reaches it.",
    # `now` is the one fact a command can need (ADR 0081) and the builder refuses a fact declared
    # twice, so no bluebook can fill the list with more than one until a second fact exists.
    "needs"       =>
                     "The runtime supplies one fact, `now`, and a repeat is refused, so a command's " \
                     "needs hold at most one row until a second fact is admitted."
  }.freeze

  # The corpus is every frozen IR, the same set `ir_golden_spec` walks.
  def observed_maxima
    max = Hash.new(0)
    walk = lambda do |node|
      case node
      when Hash
        node.each do |key, held|
          max[key] = [max[key], held.length].max if held.is_a?(Array)
          walk.call(held)
        end
      when Array then node.each { |held| walk.call(held) }
      end
    end
    Dir[File.join(InMemoryDomain::ROOT, "spec/golden/ir/*.json")].each do |file|
      walk.call(JSON.parse(File.read(file)))
    end
    max
  end

  # Every `list_of` field on every category the language uses to describe itself.
  def declared_lists
    language = Hecks::Bluebook::MetaValidator.grammar_registry.bluebook("Bluebook")
    language.aggregates.flat_map do |category|
      category.attributes.select(&:list?).map { |field| [category.hecks_name, field.name] }
    end
  end

  # One classification pass shared by the examples below: unmeasurable, plural or lonely.
  let(:list_coverage) do
    maxima    = observed_maxima
    lonely    = []
    unmeasured = []

    declared_lists.each do |category, field|
      next if derived?(category, field)

      key = WIRE_SPELLING.fetch(field, field.to_s)
      # Not skipped: a list the wire never carries cannot be measured; passing quietly is the bug.
      unless maxima.key?(key)
        unmeasured << "#{category}.#{field}"
        next
      end
      next if maxima[key] >= 2

      lonely << "#{category}.#{field}"
    end

    { unmeasured: unmeasured, lonely: lonely }
  end

  it "names every declared list the wire does not carry under any name" do
    unmeasured = list_coverage[:unmeasured]

    expect(unmeasured).to be_empty, <<~WHY
      The language declares these as lists and no golden carries a key by that
      name, so their plurality cannot be measured at all:

        #{unmeasured.join("\n        ")}

      Either the IR does not carry the field — say so in `contracts.rb`'s
      `derived:` column, which is where that fact belongs — or the wire spells it
      differently, which is a defect: add it to WIRE_SPELLING and read the note
      there about why the entry should not exist.
    WHY
  end

  it "fills every declared list with more than one, or names why it does not" do
    unnamed = list_coverage[:lonely].reject { |entry| ALLOWED_SINGLETON.key?(entry.split(".").last) }

    expect(unnamed).to be_empty, <<~WHY
      These lists are declared by the language and never filled with more than one
      anywhere in the corpus, and nothing says why:

        #{unnamed.join("\n        ")}

      A list the corpus only ever fills with one is indistinguishable from a scalar,
      so a runtime that reads the first element passes every check there is. That is
      how `identified_by` hid a parser that could not read a second path at all.

      Either add a corpus member that fills it twice — spec/corpus/domains/ exists
      for exactly this, and `market` was added for exactly this — or add an entry to
      ALLOWED_SINGLETON saying what is untested and why.
    WHY
  end

  # Holds the allowlist to the corpus both ways: an entry the corpus now covers is stale.
  it "carries no excuse the corpus has outgrown" do
    maxima = observed_maxima
    stale  = ALLOWED_SINGLETON.keys.select { |field| maxima[field].to_i >= 2 }

    expect(stale).to be_empty,
                     "the corpus now fills #{stale.join(', ')} more than once — " \
                     "delete the ALLOWED_SINGLETON entry, the claim is tested now"
  end

  # Guards the walk itself: `identified_by` is the known plural, so losing it means a broken walk.
  it "measures a plurality it is known to have" do
    expect(observed_maxima["identified_by"]).to be >= 2,
                                                "the corpus lost its composite identity, or the walk stopped seeing it"
  end
end
