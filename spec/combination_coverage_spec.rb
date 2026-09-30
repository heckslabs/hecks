require "spec_helper"
require "json"
require "hecks/fuzzing/form_census"

# Every pair of declared forms must meet on one aggregate; defects live where two forms meet.
# The form table is Hecks::Fuzzing::FormCensus, shared with hecks quality_control judge_novelty.
RSpec.describe "every pair of declared forms, met on one aggregate" do
  # The unit is one aggregate: forms on different heads never meet at dispatch.
  FormCensus = Hecks::Fuzzing::FormCensus

  # Pairs no aggregate exercises together, each with a reason. Empty on purpose.
  ALLOWED_APART = {}.freeze

  # Forms paired outside the goldens, each with the stress domain that holds it. Pairs touching
  # them are excused; the staleness check fires once the goldens pair them all.
  HELD_OUTSIDE_THE_GOLDENS = {
    "two_hop_given"      => "qa/stress_domains/referral_chain (Referral.Issue)",
    "multi_hop_where"    => "qa/stress_domains/referral_chain (Referral.FromGoodSponsors)",
    "revalued_reference" => "qa/stress_domains/referral_chain (Referral.Reassign)",
    # banking declares `corrects`, but the goldens do not pair it with the six rare forms;
    # the stress domains do.
    "corrects"           => "qa/stress_domains/corrections (Ledger.AmendEntry), " \
                            "qa/stress_domains/case_escalation (Invoice.AmendCharge)"
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

  # Held in both directions: an excuse the corpus has outgrown quietly stops gating.
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

  # The measurement has to be able to fail: the corpus carries both forms, so the census must
  # see them.
  it "sees the two forms it was blind to, on the corpus that already carried them" do
    carrying = ->(form) { aggregates.select { |_, shows| shows[form] }.map(&:first) }

    expect(carrying.call("corrects")).not_to be_empty, "no golden aggregate carries a corrects mutation"
    expect(carrying.call("role_gated")).not_to be_empty, "no golden aggregate carries a role-gated command"
  end

  # SafeDepositBox carries the rare forms together; if this fails the walk has broken.
  it "measures an aggregate it knows carries several rare forms at once" do
    box = aggregates.find { |name, _| name == "Banking::SafeDepositBox" }
    expect(box).not_to be_nil, "Banking::SafeDepositBox is gone from the goldens"

    rare = %w[composite_id two_entities composite_piece multi_emit reference_attr closed_set]
    expect(rare.select { |form| box.last[form] }).to eq(rare),
                                                     "Banking::SafeDepositBox no longer carries #{rare.reject do |f|
                                                       box.last[f]
                                                     end.join(', ')}"
  end

  # The same walk over a domain on disk, the path hecks quality_control judge_novelty measures
  # through.
  it "measures a domain on disk the same way it measures a golden" do
    transfer = FormCensus.census(File.join(InMemoryDomain::ROOT, "examples/banking"))
                         .find { |name, _| name == "Banking::Transfer" }
    expect(transfer).not_to be_nil
    expect(transfer.last.slice("two_hop_given", "reference_attr", "lifecycle"))
      .to eq("two_hop_given" => true, "reference_attr" => true, "lifecycle" => true)
  end
end
