require "spec_helper"
require "json"

# Flags any wire field that is null in every golden IR — meaning no corpus member
# has ever set it, so no parser has actually been proven to read it.
#
# Measured on the wire rather than the language: the language's own `optional`
# is a dispatch-time property that never reaches the IR, so checking it there
# would need a name-mapping table between two different questions instead.
RSpec.describe "every nullable field the wire carries, actually filled" do
  # **Unset on purpose**: an entry claims some field isn't worth a fixture and says why.
  #
  # where/where_ast: real Policy surface, dispatch-tested inline (spec/runtime/policy_spec.rb),
  #   but the Rust parser doesn't build `where` yet, so declaring one on a golden would
  #   break spec/parser_parity_spec.rb's byte-match rather than exercise this gate.
  # formerly_known_as: real and dispatch/boot-tested outside the golden corpus
  #   (spec/dsl_spec.rb, spec/adapters/driven/postgres_era/domain_rename_spec.rb).
  ALLOWED_UNSET = {
    "where"             => "new Policy surface, dispatch-tested inline -- see this file's own comment",
    "where_ast"         => "derived from `where`, so null exactly where `where` is (above); its shape is " \
                           "pinned against the Chess corpus by spec/expression_ast_spec.rb",
    "formerly_known_as" => "real and dispatch/boot-tested outside the golden corpus (spec/dsl_spec.rb, " \
                           "spec/adapters/driven/postgres_era/domain_rename_spec.rb) -- see this file's own comment"
  }.freeze

  # An object or list counts as set itself, not only via recursion into it, or a
  # present-but-empty `lifecycle` would be miscounted as never set.
  def tally_wire(node, set, absent)
    case node
    when Hash then node.each { |key, held| tally_key(key, held, set, absent) }
    when Array then node.each { |held| tally_wire(held, set, absent) }
    end
  end

  def tally_key(key, held, set, absent)
    (held.nil? ? absent : set)[key] += 1
    tally_wire(held, set, absent)
  end

  # Set/absent counts for every key across all frozen IR goldens.
  def wire_presence
    set = Hash.new(0)
    absent = Hash.new(0)
    Dir[File.join(InMemoryDomain::ROOT, "spec/golden/ir/*.json")].each do |file|
      tally_wire(JSON.parse(File.read(file)), set, absent)
    end
    [set, absent]
  end

  UNNAMED_FIELDS_WHY = <<~WHY.freeze
    These fields are null in every golden that carries them, so no bluebook in
    the tree ever declares one:

      %<names>s

    No parser has been handed a real value for these, so whatever is believed
    about them is belief by luck — no gate can exercise a keyword no
    corpus member spells. That is how `version` sat parsed and never
    once read from a real bluebook.

    Either declare one in a corpus member — spec/corpus/domains/ exists for
    exactly this — or add an entry to ALLOWED_UNSET saying why it is not worth
    a fixture.
  WHY

  it "fills every nullable field somewhere, or names why it does not" do
    set, absent = wire_presence

    # Nullable is a fact the wire states: null at least once, somewhere.
    never_filled = absent.keys.select { |key| absent[key].positive? && set[key].zero? }.sort
    unnamed      = never_filled.reject { |key| ALLOWED_UNSET.key?(key) }

    expect(unnamed).to be_empty, format(UNNAMED_FIELDS_WHY, names: unnamed.join("\n        "))
  end

  # Held in both directions, like the plurality allowlist: an excuse the corpus
  # has outgrown is how a gate quietly stops gating.
  it "carries no excuse the corpus has outgrown" do
    set, = wire_presence
    stale = ALLOWED_UNSET.keys.select { |key| set[key].to_i.positive? }

    expect(stale).to be_empty,
                     "the corpus now fills #{stale.join(", ")} — delete the " \
                     "ALLOWED_UNSET entry, the claim is tested now"
  end

  # The measurement has to be able to fail. `version` is the field this spec was
  # written out of, so if it stops being both set and absent, the walk has broken
  # rather than the corpus.
  it "measures a field it knows is exercised both ways", :aggregate_failures do
    set, absent = wire_presence

    expect(set["version"]).to be_positive, "no chapter declares a version any more"
    expect(absent["version"]).to be_positive, "every chapter declares a version — the absent case is gone"
  end
end
