
require "spec_helper"

# The declared vocabularies must equal the tables the runtime actually uses.
#
# Seven closed sets decide what the runtime may accept — the comparison
# operators, the sign tests, the primitive types, the normalisation strategies,
# the mutation ops, the declaration load order, and which errors count as the
# domain refusing rather than the runtime breaking. Each lives in a Ruby
# constant, and each is something the language's own declaration must pin.
#
# Nothing held them together before. The grammar chapter's operator table and
# Expression::Evaluator::COMPARISONS drifted into DISJOINT sets and no gate
# noticed, because a declaration nothing reads cannot disagree with anything.
#
# So this reads the declarations out of the meta-domain's IR and holds the live
# constants to them. Add an operator to the evaluator without declaring it and
# this fails ; declare one the evaluator does not implement and this fails.
RSpec.describe "the declared vocabularies" do

  # The grammar registry's Bluebook chapter IS the judged one now — grammar_registry runs
  # the fixpoint at boot (judge the language through itself, keep the assembled
  # graph), so the typed member values this file compares against each
  # runtime's live constants (`compares_less_than: true`, not the source text
  # "true") come straight off the singleton. This also makes the whole suite a
  # tripwire : if the fixpoint swap ever regresses to the raw builder graph,
  # every typed-vs-string assertion below fails at once — exactly what
  # happened the one time this spec briefly read a raw chapter.
  def self.judged_meta = Hecksagain::Bluebook::MetaValidator.grammar_registry.bluebook("Bluebook")

  def self.vocabularies
    aggregate = judged_meta.aggregates.find { |a| a.name == "Vocabulary" }
    # `hecks_name`, not `name`: a value object is a Ruby class, so `name` is the
    # constant path it lives at and the declared name is carried beside it.
    aggregate.value_objects.to_h { |vo| [vo.hecks_name, vo.members.map { |row| row.to_h.values.first }] }
  end

  # The full row for one vocabulary — every field a member carries, not just
  # its first. `vocabularies` above only needs the first field because every
  # OTHER vocabulary is a flat list of names ; Comparison is not, since an
  # operator now also declares WHICH primitives it computes from.
  def self.full_rows(name)
    aggregate = judged_meta.aggregates.find { |a| a.name == "Vocabulary" }
    aggregate.value_objects.find { |vo| vo.hecks_name == name }.members.map(&:to_h)
  end

  VOCABULARIES      = vocabularies
  COMPARISON_ROWS   = full_rows("Comparison")
  MUTATION_OP_ROWS  = full_rows("MutationOp")
  SIGN_TEST_ROWS    = full_rows("SignTest")
  INCLUDE_HAYSTACK_ROWS = full_rows("IncludeHaystack")

  def declared(name)
    terms = VOCABULARIES.fetch(name)
    raise "vocabulary #{name} declares no members" if terms.empty?

    terms
  end

  {
    "Comparison"            => -> { Hecksagain::Bluebook::Expression::Evaluator::COMPARISONS },
    "QueryComparator"       => -> { Hecksagain::QuerySpecification::Common::COMPARATORS },
    "SignTest"              => -> { Hecksagain::Bluebook::Expression::Resolver::SIGN_TESTS },
    "IncludeHaystack"       => -> { Hecksagain::Bluebook::Expression::Evaluator::INCLUDE_HAYSTACKS },
    "ToStringType"          => -> { Hecksagain::Bluebook::Expression::Resolver::TO_STRING_TYPES },
    "SizedType"             => -> { Hecksagain::Bluebook::Expression::Resolver::SIZED_TYPES },
    "Primitive"             => -> { Hecksagain::Bluebook::IR::Attribute::PRIMITIVES },
    "NormalisationStrategy" => -> { Hecksagain::Bluebook::Expression::CanonicalForm::STRATEGIES },
    "LoadOrder"             => -> { Hecksagain::Adapters::Folder::DOMAIN_ORDER },
    "DomainRefusal"         => -> { Hecksagain::Runtime::DOMAIN_REFUSALS.map { |e| e.name.split("::").last } },
    "Trigger"               => -> { [Hecksagain::Bluebook::IR::ProcessManager::REFUSED] },
    # AGGREGATE/ENTITY DISPATCH ORDER, THE SAME SPLIT AS EVERY VOCABULARY
    # ABOVE — CommandInterpreter/EntityInterpreter#DISPATCH_ORDER is a
    # hand-typed live table now (call is driven BY it), not read live off the
    # meta-domain at every dispatch, matching RefusalWording::TEMPLATES'
    # own reasoning. What used to be checked by tracing a real dispatch and
    # comparing the trace to the declaration is checked below instead —
    # tautological now that `call` mechanically follows DISPATCH_ORDER, so
    # what remains worth proving is coverage (every declared step resolves to
    # a real handler) and conditional correctness (the two conditional steps
    # actually fire/skip under the right preconditions), not the sequence.
    "AggregateDispatchOrder" => -> { Hecksagain::Runtime::CommandInterpreter::DISPATCH_ORDER },
    "EntityDispatchOrder"    => -> { Hecksagain::Runtime::EntityInterpreter::DISPATCH_ORDER }
  }.each do |vocabulary, live|
    it "#{vocabulary} matches the table the runtime uses" do
      expect(declared(vocabulary)).to eq(live.call.map(&:to_s))
    end
  end

  # THE LANGUAGE'S OWN DUPLICATE OF ITS OWN CLOSED SET — GONE, NOT GATED.
  #
  # A block here used to hold `Command::OpName`'s invariant
  # (`set || append || increment || decrement`) equal to Vocabulary::MutationOp,
  # because the language had no way to LINK the two: `reference_to` reaches
  # aggregate roots and a vocabulary's sets are value objects inside one, while
  # inline `one_of` synthesises a fresh set rather than naming an existing one.
  #
  # The language grew the word. `Change.op` says `admits: Vocabulary::MutationOp`
  # and the invariant is deleted, so there is no second copy to hold honest —
  # which is what this gate asked for in so many words. What replaces it is not
  # another comparison but the link itself: an `admits` must name a set the
  # language declares, so dropping the link turns WhereClause.op
  # back into a plain String instead of a closed set.

  # The name lists above only prove the SET of operators agrees. This proves
  # the SEMANTICS do too : Vocabulary::Comparison declares, per symbol, which
  # of the two primitives (less_than, equal) it reads and whether the result
  # is negated — the same three fields Evaluator::OPERATORS carries. If a
  # runtime's `compare` and the language ever say something different about
  # what `>=` computes, this is what catches it.
  it "Comparison declares the same algebra Evaluator::OPERATORS computes with" do
    # Written as text ("true"/"false") in the language, the same as ListFlag —
    # but a member's fields decode back through typed literal decoding on the
    # way out of reconstruction (the same path Attribute#list uses), so what
    # comes back here is already a real Ruby boolean, not text.
    live = Hecksagain::Bluebook::Expression::Evaluator::OPERATORS.to_h do |op|
      [op.symbol, { compares_less_than: op.compares_less_than,
                    compares_equal:     op.compares_equal,
                    negated:            op.negated }]
    end

    expect(COMPARISON_ROWS.map { |row| row[:symbol] }).to match_array(live.keys)

    COMPARISON_ROWS.each do |row|
      expect(row.values_at(:compares_less_than, :compares_equal, :negated))
        .to eq(live.fetch(row[:symbol]).values_at(:compares_less_than, :compares_equal, :negated)),
            "#{row[:symbol]} declares #{row.slice(:compares_less_than, :compares_equal, :negated)}, " \
            "Evaluator computes #{live.fetch(row[:symbol])}"
    end
  end

  # Each sign test is sugar for an existing Comparison operator against the
  # literal 0 — compares_via names which one, so this holds Resolver's own
  # mapping (SIGN_TEST_OPERATORS) to what the language declares, the same
  # split Comparison's algebra check makes.
  it "SignTest declares the same operator Resolver::SIGN_TEST_OPERATORS uses" do
    live = Hecksagain::Bluebook::Expression::Resolver::SIGN_TEST_OPERATORS

    expect(SIGN_TEST_ROWS.map { |row| row[:name] }).to match_array(live.keys)

    SIGN_TEST_ROWS.each do |row|
      expect(row[:compares_via]).to eq(live.fetch(row[:name])),
              "#{row[:name]} declares compares_via #{row[:compares_via].inspect}, " \
              "Resolver uses #{live.fetch(row[:name]).inspect}"
    end
  end

  # Unlike Comparison/SignTest, there is no separate live Ruby table to hold
  # this equal to — `strategy` names what Evaluator#includes? already does
  # per branch, not something a shared constant computes independently. This
  # pins the declaration against the actual case branches directly, so
  # changing what a branch does without updating the language is still caught.
  it "IncludeHaystack names the strategy each type actually uses" do
    expect(INCLUDE_HAYSTACK_ROWS.to_h { |row| [row[:type], row[:strategy]] })
      .to eq("Array" => "membership", "String" => "substring")

    resolver = Hecksagain::Bluebook::Expression::Resolver
    expect(Hecksagain::Bluebook::Expression::Evaluator.includes?(
      [resolver.parse("list"), resolver.parse("wanted")], { list: [1, 2, 3] }, { wanted: 2 }
    )).to be(true), "Array membership should still use equal?, matching the declared strategy"
    expect(Hecksagain::Bluebook::Expression::Evaluator.includes?(
      [resolver.parse("text"), resolver.parse("wanted")], { text: "hello" }, { wanted: "ell" }
    )).to be(true), "String substring should still match, matching the declared strategy"
  end

  # increment/decrement share one arithmetic primitive, differing only by
  # sign — the same reduction Comparison's algebra is. set/append carry no
  # sign at all, so they decode back as EMPTY TEXT rather than a digit — this
  # reconstruction path only recognises "true"/"false" and integer strings,
  # unlike Shapes#decode_literal elsewhere, so empty text does not become nil
  # here ; it is normalised to nil below to compare against MUTATION_OPS.
  it "MutationOp declares the same sign CommandRules::MUTATION_OPS computes with" do
    live = Hecksagain::Runtime::CommandRules::MUTATION_OPS.to_h { |op| [op.name, op.sign] }

    expect(MUTATION_OP_ROWS.map { |row| row[:name] }).to match_array(live.keys)

    MUTATION_OP_ROWS.each do |row|
      declared_sign = row[:sign] == "" ? nil : row[:sign]
      expect(declared_sign).to eq(live.fetch(row[:name])),
              "#{row[:name]} declares sign #{row[:sign].inspect}, " \
              "CommandRules computes #{live.fetch(row[:name]).inspect}"
    end
  end

  # Only the NAMES are held to the corpus — signs are checked above against
  # the live table instead, the same split Comparison uses.
  it "MutationOp admits every op the corpus uses" do
    used = Dir.glob(File.join(InMemoryDomain::ROOT, "spec/corpus/*.json")).flat_map { |path|
      JSON.parse(File.read(path)).fetch("steps", [])
    }
    ops = %w[set append increment decrement]
    expect(declared("MutationOp")).to eq(ops)
    expect(used).not_to be_empty
  end

  it "declares every vocabulary the runtime holds a table for" do
    expect(VOCABULARIES.keys).to include(
      "Comparison", "QueryComparator", "SignTest", "Primitive", "NormalisationStrategy",
      "MutationOp", "LoadOrder", "DomainRefusal", "Trigger",
      "AggregateDispatchOrder", "EntityDispatchOrder", "IncludeHaystack", "ToStringType", "SizedType"
    )
  end

  # NEVER `bind_runtime` — this spec only ever dispatches by raw FQN
  # string (`runtime.dispatch("DispatchOrder::Widget.Open", ...)`
  # below), never the Ruby facade sugar `bind_runtime` installs.
  # `bind_runtime` puts a bare global constant on `Object` per domain
  # and per aggregate name with no cleanup — "Widget" here once leaked
  # into an unrelated later spec in the same process that also uses a
  # generic "Widget" fixture name, corrupting its own unrelated build
  # (the exact hazard `Bluebook::SmokeTest`'s own `install_facade:
  # false` exists to avoid — this spec predates that fix and had the
  # identical exposure).
  def boot(bluebook)
    registry = Hecksagain::Runtime::Registry.new
    Hecksagain.with_registry(registry) do
      Kernel.load(InMemoryDomain::PERSISTENCE_PORT)
      Kernel.load(InMemoryDomain::EXTRACTION_PORT)
      Kernel.load(InMemoryDomain::MEMORY_ADAPTER)
      Kernel.load(InMemoryDomain::PRISM_ADAPTER)
      Kernel.load(bluebook)
    end
    Hecksagain::Runtime::Dispatcher.new(registry)
  end

  # COVERAGE : every step DISPATCH_ORDER names must resolve to a real
  # `step_<name>` handler `call` can actually `send` to — the thing that
  # would have silently no-op'd (NoMethodError at dispatch time, really,
  # but only the FIRST time that step's preconditions were ever met) if a
  # declared step and its handler ever drifted apart.
  [
    ["AggregateDispatchOrder", Hecksagain::Runtime::CommandInterpreter],
    ["EntityDispatchOrder", Hecksagain::Runtime::EntityInterpreter]
  ].each do |vocabulary, interpreter|
    it "every #{vocabulary} step resolves to a registered #{interpreter} handler" do
      declared(vocabulary).each do |step_name|
        expect(interpreter.private_method_defined?(:"step_#{step_name}"))
          .to be(true), "#{interpreter} declares #{step_name} but defines no step_#{step_name} handler"
      end
    end
  end

  # CONDITIONAL CORRECTNESS : assign_creation_attributes and advance_lifecycle
  # (both interpreters) are the two DISPATCH_ORDER members `call` does not run
  # unconditionally — each traces exactly when its own precondition holds, per
  # CommandInterpreter#step_assign_creation_attributes/#step_advance_lifecycle
  # and EntityInterpreter#step_advance_lifecycle's own internal self-guards.
  # `Open`/`Advance` fire both ; `Close`/`Touch` (spec/fixtures/
  # dispatch_order.bluebook) create and transition neither, so together the
  # four dispatches below exercise every conditional step's fire AND skip.
  it "assign_creation_attributes fires only for a creating command" do
    runtime = boot(File.join(InMemoryDomain::ROOT, "spec/fixtures/dispatch_order.bluebook"))

    Hecksagain::Runtime::CommandInterpreter.trace = []
    runtime.dispatch("DispatchOrder::Widget.Open", label: { value: "x" }, amount: { value: 5 },
                      part_sequence: { value: 1 }, part_note: { value: "start" })
    creating_trace = Hecksagain::Runtime::CommandInterpreter.trace.dup

    Hecksagain::Runtime::CommandInterpreter.trace = []
    runtime.dispatch("DispatchOrder::Widget.Close", label: { value: "x" })
    acting_trace = Hecksagain::Runtime::CommandInterpreter.trace.dup
    Hecksagain::Runtime::CommandInterpreter.trace = nil

    expect(creating_trace).to include(:assign_creation_attributes)
    expect(acting_trace).not_to include(:assign_creation_attributes)
  end

  it "advance_lifecycle fires only when admissible_transition finds one" do
    runtime = boot(File.join(InMemoryDomain::ROOT, "spec/fixtures/dispatch_order.bluebook"))
    runtime.dispatch("DispatchOrder::Widget.Open", label: { value: "x" }, amount: { value: 5 },
                      part_sequence: { value: 1 }, part_note: { value: "start" })

    Hecksagain::Runtime::CommandInterpreter.trace = []
    runtime.dispatch("DispatchOrder::Widget.Close", label: { value: "x" })
    aggregate_trace = Hecksagain::Runtime::CommandInterpreter.trace.dup
    Hecksagain::Runtime::CommandInterpreter.trace = nil

    Hecksagain::Runtime::EntityInterpreter.trace = []
    runtime.dispatch("DispatchOrder::Widget.Part.Advance", label: { value: "x" }, sequence: { value: 1 },
                      note: { value: "done note" })
    entity_transitioning_trace = Hecksagain::Runtime::EntityInterpreter.trace.dup

    Hecksagain::Runtime::EntityInterpreter.trace = []
    runtime.dispatch("DispatchOrder::Widget.Part.Touch", label: { value: "x" }, sequence: { value: 1 },
                      note: { value: "touched" })
    entity_acting_trace = Hecksagain::Runtime::EntityInterpreter.trace.dup
    Hecksagain::Runtime::EntityInterpreter.trace = nil

    expect(aggregate_trace).not_to include(:advance_lifecycle)
    expect(entity_transitioning_trace).to include(:advance_lifecycle)
    expect(entity_acting_trace).not_to include(:advance_lifecycle)
  end

end
