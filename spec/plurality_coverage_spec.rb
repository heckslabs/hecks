require "spec_helper"
require "json"

# A LIST THE CORPUS ONLY EVER FILLS WITH ONE IS A SCALAR AS FAR AS ANYTHING CAN TELL.
#
# The corpus specs prove the runtime answers as the frozen IR says it should,
# and perturbing a DECLARATION shows what changes. Neither can reach a form no
# corpus bluebook uses at all — there is nothing to run and nothing to perturb —
# and that is precisely where the composite identity hid.
#
# `identified_by` has been `list_of(IdentityPath)` since identity became a path.
# Every example declared exactly one, so `paths.first()` and "every path, joined"
# were the same function on the whole corpus. A reader once took the first. It
# also could not PARSE a second one: `identified_by do` opened a block the
# aggregate parser never consumed, so every attribute, command and value object
# after it was swallowed and the aggregate came back empty — silently, because
# an empty aggregate does not look like a parse failure. Green everywhere, for
# as long as the corpus said one.
#
# So this asks the language what it declares as a LIST, and asks the corpus
# whether any member ever holds two. A field that never does is not a bug on its
# own — it is a claim nobody has tested, and it must be NAMED here with a reason,
# the way `contracts.rb`'s `derived:` column names what the IR does not carry. A
# claim needs a kind.
#
# ADDING A LIST TO THE LANGUAGE AND NO CORPUS MEMBER THAT FILLS IT TWICE IS WHAT
# THIS CATCHES. That is the shape of the bug, stated once, instead of waiting for
# the next one.
RSpec.describe "every list the language declares, filled more than once" do
  # WHAT THE IR DOES NOT CARRY, in the language's own words rather than mine.
  # `contracts.rb` already declares which fields are derived and how — a parent
  # pointer, a child collection, something computed, a fold, or somewhere else
  # entirely. A list that never reaches the wire cannot be counted on the wire,
  # and asking the contract is how this avoids a hand-kept translation table.
  def derived?(category, field)
    contract = Hecksagain::Bluebook::Assembly.contract(category)
    contract.derived.key?(field)
  rescue KeyError
    false
  end

  # WHERE THE LANGUAGE AND THE WIRE DISAGREE ABOUT A NAME.
  #
  # EMPTY, AND IT SHOULD STAY EMPTY. "The language spells its fields EXACTLY as
  # the IR spells them. One spelling, so there is no translation table to be
  # quietly wrong in" — and this is that table, so an entry is a defect with a
  # workaround rather than a design.
  #
  # It held one: `Dispatch.with_spec` was spelled `with` on the wire, and only
  # there — the language, `Dispatch` and
  # `contracts.rb`'s own field map all said `with_spec`, and `to_h` renamed it on
  # the way out. The wire was the outlier, so the wire moved.
  WIRE_SPELLING = {}.freeze

  # UNREACHED ON PURPOSE — every entry is a claim the corpus does not test, and
  # every one says why it is not worth a fixture yet. Delete an entry and the
  # spec tells you whether the corpus grew to cover it.
  #
  # Each of these is a real, unverified plurality. None is known-broken; they are
  # known-UNCHECKED, which is the honest word and the reason they are written
  # down rather than skipped.
  ALLOWED_SINGLETON = {
    # EMPTY, and every entry that was here is now a corpus member instead.
    #
    #   emits             banking: SafeDepositBox.Surrender announces twice,
    #                     a policy on each (market and relay proved this
    #                     reachable first; both have since folded into banking)
    #   entities          banking: SafeDepositBox holds a Visit and a
    #                     KeyIssuance, identified by two paths and one
    #   process_managers  banking: Settlement and ExternalSettlement, two
    #                     sagas correlating independently over different
    #                     event streams
    #   read_models       banking: CustomerPortfolio and ComplianceDashboard,
    #                     projecting different roots
    #   index_hints       reflex: two hints on one ask — still the only
    #                     corpus member declaring two; nothing about banking's
    #                     own indexed queries needed a second hint
    #
    # Each was deleted because the guard below demanded it once the corpus grew.
  }.freeze

  # The corpus is every frozen IR, which is every chapter in the tree — the same
  # set `ir_golden_spec` walks, and for the same reason: a shape only one
  # bluebook exercises is exactly the shape a partial corpus lets through.
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
    Dir[File.join(InMemoryDomain::ROOT, "spec/golden/ir/*.json")].sort.each do |file|
      walk.call(JSON.parse(File.read(file)))
    end
    max
  end

  # Every `list_of` field on every category the language uses to describe itself.
  def declared_lists
    language = Hecksagain::Bluebook::MetaValidator.grammar_registry.bluebook("Bluebook")
    language.aggregates.flat_map do |category|
      category.attributes.select(&:list?).map { |field| [category.hecks_name, field.name] }
    end
  end

  it "fills every declared list with more than one, or names why it does not" do
    maxima    = observed_maxima
    lonely    = []
    unmeasured = []

    declared_lists.each do |category, field|
      next if derived?(category, field)

      key = WIRE_SPELLING.fetch(field, field.to_s)
      # NOT SKIPPED. A declared list the wire does not carry under any name it
      # gave me is the one case this gate cannot measure, and an unmeasurable
      # field passing quietly is the failure this whole spec is about.
      unless maxima.key?(key)
        unmeasured << "#{category}.#{field}"
        next
      end
      next if maxima[key] >= 2

      lonely << "#{category}.#{field}"
    end

    expect(unmeasured).to be_empty, <<~WHY
      The language declares these as lists and no golden carries a key by that
      name, so their plurality cannot be measured at all:

        #{unmeasured.join("\n        ")}

      Either the IR does not carry the field — say so in `contracts.rb`'s
      `derived:` column, which is where that fact belongs — or the wire spells it
      differently, which is a defect: add it to WIRE_SPELLING and read the note
      there about why the entry should not exist.
    WHY

    unnamed = lonely.reject { |entry| ALLOWED_SINGLETON.key?(entry.split(".").last) }

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

  # THE ALLOWLIST IS HELD TO THE CORPUS IN BOTH DIRECTIONS. An entry that the
  # corpus has since grown to cover is a stale excuse, and a stale excuse is how a
  # gate quietly stops gating.
  it "carries no excuse the corpus has outgrown" do
    maxima = observed_maxima
    stale  = ALLOWED_SINGLETON.keys.select { |field| maxima[field].to_i >= 2 }

    expect(stale).to be_empty,
                     "the corpus now fills #{stale.join(', ')} more than once — " \
                     "delete the ALLOWED_SINGLETON entry, the claim is tested now"
  end

  # The measurement itself has to be able to fail. `identified_by` reaching two is
  # what this whole spec was written out of, so if it ever stops, the walk has
  # broken rather than the corpus.
  it "measures a plurality it is known to have" do
    expect(observed_maxima["identified_by"]).to be >= 2,
                                                "the corpus lost its composite identity, or the walk stopped seeing it"
  end
end
