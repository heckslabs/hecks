require "spec_helper"
require "json"

# A FORM EXERCISED ALONE IS NOT A FORM EXERCISED.
#
# The third coverage gate, and the one the other two set up. `plurality` asks
# whether a declared list is ever filled twice. `optionality` asks whether a
# nullable field is ever filled at all. Both measure one property at a time —
# and every defect this arc found lived where two met:
#
#   a composite identity  ×  a Rust parser        the block was never consumed,
#                                                 and the aggregate came back empty
#   a composite identity  ×  an entity            the element matched on the
#                                                 first part of the piece's id
#   two events            ×  a reaction           nothing had ever ordered two
#                                                 announcements from one dispatch
#   a plain argument      ×  a cross-reference    the two parsers disagreed about
#                                                 attribute ORDER, and only because
#                                                 no command had ever declared them
#                                                 in that order
#
# The last one is this spec's own catch, and it is the argument for the whole
# idea: both runtimes were right about references and right about arguments, and
# wrong together the first time a command put an argument before a reference.
#
# PAIRWISE, NOT EVERY SUBSET. Thirteen properties is 78 pairs and 8192 subsets;
# pairwise is the standard tractable cut and it is where the interactions above
# actually lived. It is also cheap to satisfy well: the corpus went from 27
# uncovered pairs to 3 by enriching ONE aggregate, because the gaps cluster
# around the rare forms rather than spreading evenly.
#
# THE UNIT IS ONE AGGREGATE. Two forms in the same chapter but different heads
# never meet at dispatch; two forms on one head do.
RSpec.describe "every pair of declared forms, met on one aggregate" do
  # WHAT AN AGGREGATE CAN EXHIBIT. Each entry is a form the language declares
  # and a runtime has to handle — chosen because it has produced a defect, or
  # sits one step from one. Adding a property here is how a new form joins the
  # gate; it will name its own uncovered pairs on the first run.
  def properties(aggregate)
    pieces     = aggregate["entities"] || []
    commands   = aggregate["commands"] || []
    attributes = aggregate["attributes"] || []
    {
      "composite_id"    => (aggregate["identified_by"] || []).size >= 2,
      "has_entity"      => pieces.any?,
      "two_entities"    => pieces.size >= 2,
      "composite_piece" => pieces.any? { |piece| (piece["identified_by"] || []).size >= 2 },
      "multi_emit"      => commands.any? { |verb| (verb["emits"] || []).size >= 2 },
      "lifecycle"       => !aggregate["lifecycle"].nil?,
      "piece_lifecycle" => pieces.any? { |piece| !piece["lifecycle"].nil? },
      "has_query"       => (aggregate["queries"] || []).any?,
      "list_attr"       => attributes.any? { |held| held["list"] },
      "reference_attr"  => attributes.any? { |held| held["type"].to_s.start_with?("Reference<") },
      "closed_set"      => (aggregate["value_objects"] || []).any? { |shape| shape["closed_set"] },
      "has_default"     => attributes.any? { |held| !held["default"].nil? },
      "has_optional"    => commands.any? { |verb| (verb["attributes"] || []).any? { |held| held["optional"] } }
    }
  end

  # UNMET ON PURPOSE — and empty, which is the position to defend. An entry
  # would be a pair of forms no aggregate exercises together, with a reason.
  ALLOWED_APART = {}.freeze

  def aggregates
    Dir[File.join(InMemoryDomain::ROOT, "spec/golden/ir/*.json")].sort.flat_map do |file|
      chapter = File.basename(file, ".json")
      (JSON.parse(File.read(file))["aggregates"] || []).map do |aggregate|
        ["#{chapter}::#{aggregate['name']}", properties(aggregate)]
      end
    end
  end

  it "meets every pair of forms on some aggregate, or names why it does not" do
    held  = aggregates
    forms = held.first.last.keys

    apart = forms.combination(2).reject do |left, right|
      held.any? { |_, shows| shows[left] && shows[right] }
    end
    unnamed = apart.reject { |pair| ALLOWED_APART.key?(pair.sort.join(" + ")) }

    expect(unnamed).to be_empty, <<~WHY
      These forms are each exercised somewhere, and never on the SAME aggregate:

        #{unnamed.map { |left, right| "#{left} + #{right}" }.join("\n        ")}

      Both runtimes can be right about each form alone and wrong about the two
      together — that is how a command declaring an argument before a
      cross-reference put Ruby's and Rust's attribute order out of step, having
      agreed on every command in the corpus that declared them the other way.

      Closing these is cheaper than it looks: the gaps cluster on the rare forms,
      so enriching one aggregate that already carries a rare one usually closes
      many pairs at once. Otherwise add an entry to ALLOWED_APART, keyed
      "left + right" alphabetically, saying why the two need not meet.
    WHY
  end

  # Held in both directions, like the other two gates: an excuse the corpus has
  # outgrown is how a gate quietly stops gating.
  it "carries no excuse the corpus has outgrown" do
    held  = aggregates
    stale = ALLOWED_APART.keys.select do |key|
      left, right = key.split(" + ")
      held.any? { |_, shows| shows[left] && shows[right] }
    end

    expect(stale).to be_empty,
                     "the corpus now meets #{stale.join(', ')} on one aggregate — " \
                     "delete the ALLOWED_APART entry, the claim is tested now"
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
                                                     "Banking::SafeDepositBox no longer carries #{rare.reject { |f| box.last[f] }.join(', ')}"
  end
end
