require "spec_helper"

# `Vocabulary::QueryComparator` (language/bluebook/vocabulary.bluebook) and
# `rust/src/kernel/query_comparators.rs`'s own hand-maintained
# `QueryComparator` enum are two independent lists of the same closed
# set, with NOTHING holding them in parity — exactly the shape item #2's
# real, 39-vs-42-entry refusal-wording drift went unnoticed for, and
# exactly the drift item #9 (whole-project table-unification survey)
# found here: `Vocabulary::QueryComparator` had grown a ninth name
# (`none_in_state`) that `query_comparators.rs`'s own `ALL`/`parse` never
# caught up to, for however long that drift was already live before this
# spec — and this file's own header explicitly says why
# `bin/project_kernel_capabilities` can never close this particular gap
# the way it does `attribute_shapes`/`expression_operators`: once a real
# dispatch site exists, `query_comparators.rs` becomes hand-maintained
# code, not a generated roster, so there is nothing left for a generator
# to regenerate. This spec is the gate a generator can't be, the same
# shape spec/kernel_capabilities_conformance_spec.rb already is for the
# two capabilities that ARE still generated.
RSpec.describe "QueryComparator, held to Rust's own hand-maintained enum" do
  RUST_SOURCE = File.read(File.join(InMemoryDomain::ROOT, "rust/src/kernel/query_comparators.rs")).freeze

  # `parse`'s own match arms — the real, load-bearing contract (the wire
  # protocol's own recognized strings), read straight off the source
  # rather than assumed.
  PARSE_WIRE_NAMES = RUST_SOURCE.scan(/^\s*"(\w+)"\s*=>\s*Some\(QueryComparator::\w+\),?\s*$/).flatten.freeze

  # `ALL`'s own entries — isolated to the `pub const ALL = &[ ... ];`
  # block specifically, not a blind scan of the whole file (`matches`'s
  # own match arms mention `QueryComparator::<Variant>` too, on the LEFT
  # of `=>`, which a looser scan would double-count).
  ALL_BLOCK = RUST_SOURCE[/pub const ALL: &'static \[QueryComparator\] = &\[(.*?)\];/m, 1] or
    raise "query_comparators.rs's own QueryComparator::ALL block could not be found — has it been renamed?"
  ALL_VARIANT_NAMES = ALL_BLOCK.scan(/QueryComparator::(\w+)/).flatten.freeze

  it "recognizes exactly the wire names Vocabulary::QueryComparator declares, both directions" do
    live = Hecks::Vocabulary.symbols("QueryComparator").map(&:to_s)
    expect(PARSE_WIRE_NAMES).to match_array(live),
                                "rust/src/kernel/query_comparators.rs's own QueryComparator::parse recognizes " \
                                "#{PARSE_WIRE_NAMES.inspect}, but Vocabulary::QueryComparator declares " \
                                "#{live.inspect} — a human needs to add/remove a variant, parse arm, ALL entry, " \
                                "and matches arm by hand (query_comparators.rs's own header: this file is no " \
                                "longer generated once a real dispatch site exists)"
  end

  # A cheaper, narrower sanity check that `ALL` (the roster `matches`'s
  # own exhaustiveness, and any future `#[cfg(test)]` fixture walk, both
  # rely on) has not silently drifted apart from `parse` itself — the one
  # way the two could disagree that the wire-name check above, which only
  # reads `parse`, would never catch on its own.
  it "declares the same variant COUNT in ALL as it recognizes wire names in parse" do
    expect(ALL_VARIANT_NAMES.size).to eq(PARSE_WIRE_NAMES.size),
                                      "QueryComparator::ALL lists #{ALL_VARIANT_NAMES.size} variant(s) " \
                                      "(#{ALL_VARIANT_NAMES.inspect}) but parse recognizes " \
                                      "#{PARSE_WIRE_NAMES.size} wire name(s) — they should name the same set"
  end
end
