
require "spec_helper"

# Every VERB the language declares must be OFFERED to it.
#
# A rule the judge never dispatches input to cannot fire. That has now happened
# three times in this validator. Five rules were declared and unreachable after
# the first pass. Policies, process managers and entities went unjudged after
# the second — banking's three policies and its Settlement saga passed through
# validation untouched, so any rule about them was decoration. This spec was
# written to catch the third, and did not, because it guarded only `*.Declare`:
# thirteen verbs — among them `Command.Argument` and `ValueObject.Field`, so a
# command's own arguments and a value object's own fields were NEVER judged —
# sat declared and unreachable underneath a green guard.
#
# So the map is gone. Nothing here is hand-kept any more: the expectation is
# DERIVED from the language, and a verb the language declares is a verb the
# judge owes an offer. Adding a command to bluebook.bluebook without teaching
# the judge to offer it is exactly the failure this catches, and now it catches
# it at the grain of the verb rather than the grain of the category.
#
# `experiment/replay.rb` used to catch this indirectly: it rebuilt the IR from
# the meta-domain and diffed, so a dropped category stopped matching. That is a
# lot of machinery to answer a question this asks directly, and the reconstruction
# half was never needed for validation. This replaces it.
RSpec.describe "the judge's coverage of the language" do
  # Banking is the only corpus member carrying every category at once.
  # Booted ONCE per file — `dispatch` in the examples below always goes
  # through a `Spy` double, never the real banking runtime, so nothing
  # here ever mutates and a shared boot is safe.
  before(:context) do
    registry = Hecksagain::Runtime::Registry.new
    Hecksagain.with_registry(registry) do
      Kernel.load(InMemoryDomain::PERSISTENCE_PORT)
      Kernel.load(InMemoryDomain::EXTRACTION_PORT)
      Kernel.load(InMemoryDomain::MEMORY_ADAPTER)
      Kernel.load(InMemoryDomain::PRISM_ADAPTER)
      Kernel.load(File.join(InMemoryDomain::ROOT, "examples/banking/bluebook/banking.bluebook"))
    end
    @banking = registry.bluebook("Banking")
  end

  def banking = @banking

  # Records what the judge asks for, without judging anything.
  class Spy
    attr_reader :verbs

    def initialize = @verbs = []
    def dispatch(verb, **_args) = @verbs << verb
    def registry = nil
  end

  def offered_in_order(bluebook = banking)
    spy = Spy.new
    judge = Hecksagain::Bluebook::MetaValidator::Judge.allocate
    judge.instance_variable_set(:@bluebook, bluebook)
    judge.instance_variable_set(:@refusals, [])
    judge.instance_variable_set(:@runtime, spy)
    judge.instance_variable_set(
      :@plan,
      Hecksagain::Bluebook::MetaValidator::Plan.for(Hecksagain::Bluebook::MetaValidator.grammar_registry)
    )
    judge.send(:judge!)
    spy.verbs
  end

  # BANKING ALONE, now — it used to declare no query options, so
  # `Query.Option` and `ReadModel.Option` were never offered and this gate
  # called them decoration (correctly: a verb nothing dispatches carries
  # rules that cannot fire). The fix was to exercise them somewhere rather
  # than excuse them; that used to mean unioning in `reflex.bluebook`
  # (the one chapter that declared every option a query or read_model can
  # carry), but banking now carries both itself — `Account.Overdrawn`'s
  # `freshness`/`use_index`, `SafeDepositBox.Rented`'s
  # `authorize`/`consistency`, `ComplianceDashboard`'s own
  # `freshness`/`use_index` — so the union is gone with it.
  def offered_verbs = offered_in_order

  # Every command on every aggregate of the meta-domain, spelled as the judge
  # would dispatch it. World and Wiring live in world.bluebook and are judged
  # through their own door (MetaValidator.call_world), so `bluebook("Bluebook")`
  # leaves them out by construction rather than by exclusion list. Vocabulary
  # declares no commands, so it contributes nothing and needs no special case —
  # it is static declaration read from the IR by spec/vocabulary_conformance_spec.
  # S14, ADR 0026 — "Syntax" is named here for the SAME reason
  # "Vocabulary" always was (it declares no commands, so `.commands`
  # would find it empty anyway — but Syntax now DOES declare real
  # commands): its own data is dispatched by `SyntaxBoot`, a dedicated,
  # separate mechanism that seeds the language's own grammar table from
  # its own still-static seed rows — never by `Judge`'s own walk, which
  # only ever finds an EMPTY `keywords`/`arguments` list on the raw,
  # statically-built "Syntax" node (no real domain, including the meta-
  # domain itself, ever declares Syntax data through the ordinary DSL).
  META_ONLY_AGGREGATES = %w[Vocabulary Syntax].freeze

  def declared_verbs
    Hecksagain::Bluebook::MetaValidator.grammar_registry
      .bluebook("Bluebook").aggregates
      .reject { |aggregate| META_ONLY_AGGREGATES.include?(aggregate.hecks_name) }
      .flat_map { |aggregate| aggregate_verbs(aggregate) }
  end

  # S17, ADR 0026 — Member is a genuine entity now, nested under
  # ValueObject rather than its own root aggregate, so its own commands no
  # longer show up in `aggregate.commands` — they are in `aggregate.
  # entities.first.commands`, and the judge reaches them through a DOTTED
  # verb (`ValueObject.Member.Pair`, `Judge#verb_for`), never a bare one.
  # Recurses — `Dispatch`, inside `Handler`, nests two levels deep, not
  # one, and `entity_verbs` walks a nested entity's own further-nested
  # ones the same way `Judge#dotted_prefix` builds the verb string.
  def aggregate_verbs(aggregate)
    aggregate.commands.map { |c| "Bluebook::#{aggregate.name}.#{c.hecks_name}" } +
      aggregate.entities.flat_map { |entity| entity_verbs(aggregate.name, entity) }
  end

  def entity_verbs(prefix, entity)
    dotted = "#{prefix}.#{entity.hecks_name}"
    entity.commands.map { |c| "Bluebook::#{dotted}.#{c.hecks_name}" } +
      entity.entities.flat_map { |piece| entity_verbs(dotted, piece) }
  end

  it "offers every verb the language declares" do
    missing = declared_verbs - offered_verbs

    expect(missing).to be_empty,
                       "the language declares #{missing.size} verb(s) the judge never offers, " \
                       "so every rule hanging off them is decoration:\n  #{missing.join("\n  ")}"
  end

  it "offers no verb the language does not declare" do
    # The judge swallows Runtime::UnknownVerb, so a misspelled or retired verb
    # is dispatched into silence and every rule it was carrying stops firing
    # with nothing going red. This is the other half of the same failure.
    phantom = offered_verbs - declared_verbs

    expect(phantom).to be_empty,
                       "the judge offers #{phantom.size} verb(s) the language does not declare; " \
                       "UnknownVerb is swallowed, so these dispatch into silence:\n  #{phantom.join("\n  ")}"
  end

  it "declares every aggregate before it details any of them" do
    # An aggregate's attributes are offered AFTER every aggregate exists, not after
    # the ones that happen to be written above it. Banking survives the old order
    # by luck — Customer is declared above Account, which is the only reason
    # Account#customer_id could ever point at anything.
    #
    # This is what lets a reference be a REFERENCE: `points_at` can resolve against
    # a head declared later in the file. Pinned here because the ordering is
    # invisible until that lands, and an invariant nothing watches is one somebody
    # optimises away.
    verbs = offered_in_order

    expect(verbs.rindex("Bluebook::Aggregate.Declare"))
      .to be < verbs.index("Bluebook::Aggregate.Attribute")
  end
end
