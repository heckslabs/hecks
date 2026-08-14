require "spec_helper"
require "json"

# A FIELD THE CORPUS NEVER SETS IS A FIELD THE RUNTIME HAS NEVER BEEN ASKED TO READ.
#
# The sibling of spec/plurality_coverage_spec.rb, in the other direction. That one
# asks whether a declared LIST is ever filled with two. This asks whether a
# NULLABLE field is ever filled at all.
#
# The wire says which fields are nullable without being asked: a key that is null
# in some golden and set in another is exercised both ways, and there is nothing
# to check. A key that is null in EVERY golden it appears in is a field the corpus
# declares nowhere — so no parser has ever read it from a real bluebook, and
# anything believed about it is a guess, not a measurement.
#
# `version` was exactly that. `Hecks.bluebook "Pizzas", version: "v2"` has been
# in the language since the language held a chapter's version ; the builder
# parses it — `BluebookBuilder.new(name, version:)` — and not one of the ten
# chapters in the tree declared one. A keyword accepted that had never once
# been handed a value. `spec/corpus/domains/relay` was the first corpus member to
# declare one, proving the keyword is really read, before that domain folded into
# banking (`Hecks.bluebook "Banking", version: "v1"`) and carried the proof forward.
#
# WHY THIS IS MEASURED ON THE WIRE AND NOT FROM THE LANGUAGE. The language's
# `optional` marks a COMMAND ARGUMENT that may be left out — a dispatch-time
# property that never appears in the IR at all. Reading optionality off the
# language and looking for it in the goldens conflates two different questions
# and needs a name-mapping table between them, which is the thing this project
# keeps finding quietly wrong. The wire is self-describing here, so it is the
# honest source.
RSpec.describe "every nullable field the wire carries, actually filled" do
  # UNSET ON PURPOSE. Nothing is here, and that is the point — the corpus
  # currently fills every nullable field it carries. An entry would be a claim
  # that some field is not worth a fixture, and it would need to say why.
  #
  # `count`/`median_field` (`ReadModel`'s two new reductions) do NOT need
  # an entry despite being new and genuinely nullable: `ReadModel#to_h`
  # OMITS the key entirely rather than emitting `null` when neither is
  # declared (the same "ABSENT is not EMPTY" reading `extra_options_to_h`
  # already gives `cursor`/`offset`/etc), so a read model that declares
  # neither carries no `count`/`median_field` key at all for this spec's
  # own `wire_presence` walk to see — and banking.bluebook's own real
  # `DisputedPaymentCount`/`DisputedPaymentMedian` set them for real, so
  # there is nothing unexercised to name here even if it did.
  ALLOWED_UNSET = {}.freeze

  # SET and NULL counts for every key in every frozen IR. An object or a list
  # counts as SET: `lifecycle` is a Hash when it is there and null when it is
  # not, and a walk that recursed into it without counting it reported the field
  # as never set — which is how this spec's first draft invented three findings
  # that were artefacts of its own measurement.
  def wire_presence
    set = Hash.new(0)
    absent = Hash.new(0)
    walk = lambda do |node|
      case node
      when Hash
        node.each do |key, held|
          held.nil? ? (absent[key] += 1) : (set[key] += 1)
          walk.call(held)
        end
      when Array then node.each { |held| walk.call(held) }
      end
    end
    Dir[File.join(InMemoryDomain::ROOT, "spec/golden/ir/*.json")].sort.each do |file|
      walk.call(JSON.parse(File.read(file)))
    end
    [set, absent]
  end

  it "fills every nullable field somewhere, or names why it does not" do
    set, absent = wire_presence

    # Nullable is a fact the wire states: null at least once, somewhere.
    never_filled = absent.keys.select { |key| absent[key].positive? && set[key].zero? }.sort
    unnamed      = never_filled.reject { |key| ALLOWED_UNSET.key?(key) }

    expect(unnamed).to be_empty, <<~WHY
      These fields are null in every golden that carries them, so no bluebook in
      the tree ever declares one:

        #{unnamed.join("\n        ")}

      No parser has been handed a real value for these, so whatever is believed
      about them is belief by luck — no gate can exercise a keyword no
      corpus member spells. That is how `version` sat parsed and never
      once read from a real bluebook.

      Either declare one in a corpus member — spec/corpus/domains/ exists for
      exactly this — or add an entry to ALLOWED_UNSET saying why it is not worth
      a fixture.
    WHY
  end

  # Held in both directions, like the plurality allowlist: an excuse the corpus
  # has outgrown is how a gate quietly stops gating.
  it "carries no excuse the corpus has outgrown" do
    set, = wire_presence
    stale = ALLOWED_UNSET.keys.select { |key| set[key].to_i.positive? }

    expect(stale).to be_empty,
                     "the corpus now fills #{stale.join(', ')} — delete the " \
                     "ALLOWED_UNSET entry, the claim is tested now"
  end

  # The measurement has to be able to fail. `version` is the field this spec was
  # written out of, so if it stops being both set and absent, the walk has broken
  # rather than the corpus.
  it "measures a field it knows is exercised both ways" do
    set, absent = wire_presence

    expect(set["version"]).to be_positive, "no chapter declares a version any more"
    expect(absent["version"]).to be_positive, "every chapter declares a version — the absent case is gone"
  end
end
