require "spec_helper"
require "json"
require "hecks/fuzzing/form_census"

# A FORM EXERCISED ALONE IS NOT A FORM EXERCISED.
#
# The third coverage gate, and the one the other two set up. `plurality` asks
# whether a declared list is ever filled twice. `optionality` asks whether a
# nullable field is ever filled at all. Both measure one property at a time —
# and every defect this arc found lived where two met:
#
#   a composite identity  ×  a hand-written parser  the block was never consumed,
#                                                 and the aggregate came back empty
#   a composite identity  ×  an entity            the element matched on the
#                                                 first part of the piece's id
#   two events            ×  a reaction           nothing had ever ordered two
#                                                 announcements from one dispatch
#   a plain argument      ×  a cross-reference    the derived attribute ORDER
#                                                 came out wrong, and only because
#                                                 no command had ever declared them
#                                                 in that order
#
# The last one is this spec's own catch, and it is the argument for the whole
# idea: a reader can be right about references and right about arguments, and
# wrong the first time a command puts an argument before a reference.
#
# PAIRWISE, NOT EVERY SUBSET. Thirteen properties is 78 pairs and 8192 subsets;
# pairwise is the standard tractable cut and it is where the interactions above
# actually lived. It is also cheap to satisfy well: the corpus went from 27
# uncovered pairs to 3 by enriching ONE aggregate, because the gaps cluster
# around the rare forms rather than spreading evenly.
#
# THE UNIT IS ONE AGGREGATE. Two forms in the same chapter but different heads
# never meet at dispatch; two forms on one head do.
#
# THE TABLE ITSELF LIVES IN `Hecks::Fuzzing::FormCensus` (lib/hecks/fuzzing/
# form_census.rb) — extracted so `bin/qa_domain_novelty` (the gate a NEW
# stress domain has to pass before it joins the QA rotation: does it put
# two forms together that no existing target does?) measures with the
# identical census this spec holds the golden corpus to. One table, two
# gates; a form added there joins both.
RSpec.describe "every pair of declared forms, met on one aggregate" do
  FormCensus = Hecks::Fuzzing::FormCensus

  # UNMET ON PURPOSE — and empty, which is the position to defend. An entry
  # would be a pair of forms no aggregate exercises together, with a reason.
  ALLOWED_APART = {}.freeze

  # HELD OUTSIDE THE GOLDENS, ON PURPOSE. The reference-hop family joined
  # the census with `qa/stress_domains/referral_chain` (ANGLE-2) — forms
  # the golden corpus was never enriched to pair with everything else,
  # because the place a rare reference shape gets exercised against the
  # rest of the language is a STRESS DOMAIN in the QA rotation, measured
  # by `bin/qa_domain_novelty` against every ledger target, not a
  # teaching example pinned in spec/golden. Every pair touching one of
  # these forms is excused from the golden gate here, by form, with the
  # domain that holds it; the staleness check below still fires the day
  # the goldens meet every one of that form's pairs on their own.
  HELD_OUTSIDE_THE_GOLDENS = {
    "two_hop_given"      => "qa/stress_domains/referral_chain (Referral.Issue)",
    "multi_hop_where"    => "qa/stress_domains/referral_chain (Referral.FromGoodSponsors)",
    "revalued_reference" => "qa/stress_domains/referral_chain (Referral.Reassign)"
  }.freeze

  def aggregates
    Dir[File.join(InMemoryDomain::ROOT, "spec/golden/ir/*.json")].flat_map do |file|
      FormCensus.aggregates_in(JSON.parse(File.read(file)))
    end
  end

  def held_outside?(pair)
    pair.any? { |form| HELD_OUTSIDE_THE_GOLDENS.key?(form) }
  end

  it "meets every pair of forms on some aggregate, or names why it does not" do
    covered = FormCensus.covered_pairs(aggregates)

    apart = FormCensus::FORMS.keys.combination(2).reject do |pair|
      covered.key?(FormCensus.pair_key(*pair)) || held_outside?(pair)
    end
    unnamed = apart.reject { |pair| ALLOWED_APART.key?(FormCensus.pair_key(*pair)) }

    expect(unnamed).to be_empty, <<~WHY
      These forms are each exercised somewhere, and never on the SAME aggregate:

        #{unnamed.map { |left, right| "#{left} + #{right}" }.join("\n        ")}

      A runtime can be right about each form alone and wrong about the two
      together — that is how a command declaring an argument before a
      cross-reference put the derived attribute order out of step, having
      been right on every command in the corpus that declared them the other way.

      Closing these is cheaper than it looks: the gaps cluster on the rare forms,
      so enriching one aggregate that already carries a rare one usually closes
      many pairs at once. Otherwise add an entry to ALLOWED_APART, keyed
      "left + right" alphabetically, saying why the two need not meet.
    WHY
  end

  # Held in both directions, like the other two gates: an excuse the corpus has
  # outgrown is how a gate quietly stops gating.
  it "carries no excuse the corpus has outgrown" do
    covered = FormCensus.covered_pairs(aggregates)
    stale = ALLOWED_APART.keys.select { |key| covered.key?(key) }

    expect(stale).to be_empty,
                     "the corpus now meets #{stale.join(', ')} on one aggregate — " \
                     "delete the ALLOWED_APART entry, the claim is tested now"
  end

  it "holds outside the goldens only forms the goldens do not yet pair with everything" do
    covered = FormCensus.covered_pairs(aggregates)
    outgrown = HELD_OUTSIDE_THE_GOLDENS.keys.select do |form|
      (FormCensus::FORMS.keys - [form]).all? { |other| covered.key?(FormCensus.pair_key(form, other)) }
    end

    expect(outgrown).to be_empty,
                        "the goldens now meet every pair of #{outgrown.join(', ')} on their own — " \
                        "delete the HELD_OUTSIDE_THE_GOLDENS entry, the gate holds them now"
  end

  it "names only census forms in its excuse tables" do
    unknown = (ALLOWED_APART.keys.flat_map { |key| key.split(" + ") } + HELD_OUTSIDE_THE_GOLDENS.keys) -
              FormCensus::FORMS.keys
    expect(unknown).to be_empty, "#{unknown.inspect} is not a form Hecks::Fuzzing::FormCensus::FORMS declares"
  end

  # The measurement has to be able to fail. Banking's SafeDepositBox is the
  # aggregate that carries the rare forms together now — Market::Stall proved
  # the same six reachable before that domain folded into banking; if this
  # stops, the walk has broken rather than the corpus.
  it "measures an aggregate it knows carries several rare forms at once" do
    box = aggregates.find { |name, _| name == "Banking::SafeDepositBox" }
    expect(box).not_to be_nil, "Banking::SafeDepositBox is gone from the goldens"

    rare = %w[composite_id two_entities composite_piece multi_emit reference_attr closed_set]
    expect(rare.select { |form| box.last[form] }).to eq(rare),
                                                     "Banking::SafeDepositBox no longer carries #{rare.reject do |f|
                                                       box.last[f]
                                                     end.join(', ')}"
  end

  # The same walk, over a domain on disk instead of a golden file — the
  # path `bin/qa_domain_novelty` measures a candidate through. Banking's
  # own `Transfer.Request` is the golden corpus's one two-hop given
  # (`source.customer.status`), so the disk census has to see it too.
  it "measures a domain on disk the same way it measures a golden" do
    transfer = FormCensus.census(File.join(InMemoryDomain::ROOT, "examples/banking"))
                         .find { |name, _| name == "Banking::Transfer" }
    expect(transfer).not_to be_nil
    expect(transfer.last.slice("two_hop_given", "reference_attr", "lifecycle"))
      .to eq("two_hop_given" => true, "reference_attr" => true, "lifecycle" => true)
  end
end
