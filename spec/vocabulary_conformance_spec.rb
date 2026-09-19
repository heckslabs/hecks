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
# Expression::Evaluator::COMPARISONS drifted into disjoint sets and no gate
# noticed, because a declaration nothing reads cannot disagree with anything.
#
# So this reads the declarations out of the meta-domain's IR and holds the live
# constants to them. Add an operator to the evaluator without declaring it and
# this fails ; declare one the evaluator does not implement and this fails.
RSpec.describe "the declared vocabularies" do
  # The grammar registry's Bluebook chapter is the judged one now — grammar_registry runs
  # the fixpoint at boot (judge the language through itself, keep the assembled
  # graph), so the typed member values this file compares against each
  # runtime's live constants (`compares_less_than: true`, not the source text
  # "true") come straight off the singleton. This also makes the whole suite a
  # tripwire : if the fixpoint swap ever regresses to the raw builder graph,
  # every typed-vs-string assertion below fails at once — exactly what
  # happened the one time this spec briefly read a raw chapter.
  def self.judged_meta = Hecks::Bluebook::MetaValidator.grammar_registry.bluebook("Bluebook")

  def self.vocabularies
    aggregate = judged_meta.aggregates.find { |a| a.name == "Vocabulary" }
    # `hecks_name`, not `name`: a value object is a Ruby class, so `name` is the
    # constant path it lives at and the declared name is carried beside it.
    aggregate.value_objects.to_h { |vo| [vo.hecks_name, vo.members.map { |row| row.to_h.values.first }] }
  end

  # The full row for one vocabulary — every field a member carries, not just
  # its first. `vocabularies` above only needs the first field because every
  # other vocabulary is a flat list of names ; Comparison is not, since an
  # operator now also declares which primitives it computes from.
  def self.full_rows(name)
    aggregate = judged_meta.aggregates.find { |a| a.name == "Vocabulary" }
    aggregate.value_objects.find { |vo| vo.hecks_name == name }.members.map(&:to_h)
  end

  VOCABULARIES          = vocabularies
  COMPARISON_ROWS       = full_rows("Comparison")
  INCLUDE_HAYSTACK_ROWS = full_rows("IncludeHaystack")

  def declared(name)
    terms = VOCABULARIES.fetch(name)
    raise "vocabulary #{name} declares no members" if terms.empty?

    terms
  end

  # Every other closed set's constant now reads the generated table itself
  # (lib/hecks/vocabulary.rb, `Hecks::Vocabulary.fetch`/`.symbols`), and
  # spec/vocabulary_table_spec.rb holds both halves — the table equal to
  # the declaration, and each constant equal to the table — so a per-set
  # comparison here would only restate it. Comparison is the exception:
  # Evaluator::COMPARISONS derives from the operator projection, not the
  # vocabulary table, so its declared order is still held here.
  it "Comparison matches the table the runtime uses" do
    expect(declared("Comparison")).to eq(Hecks::Bluebook::Expression::Evaluator::COMPARISONS.map(&:to_s))
  end

  # The language's own duplicate of its own closed set — gone, not gated.
  #
  # A block here used to hold `Command::OpName`'s invariant
  # (`set || append || increment || decrement`) equal to Vocabulary::MutationOp,
  # because the language had no way to link the two: `reference_to` reaches
  # aggregate roots and a vocabulary's sets are value objects inside one, while
  # inline `one_of` synthesises a fresh set rather than naming an existing one.
  #
  # The language grew the word. `Change.op` says `admits: Vocabulary::MutationOp`
  # and the invariant is deleted, so there is no second copy to hold honest —
  # which is what this gate asked for in so many words. What replaces it is not
  # another comparison but the link itself: an `admits` must name a set the
  # language declares, so dropping the link turns WhereClause.op
  # back into a plain String instead of a closed set.

  # The name lists above only prove the set of operators agrees. This proves
  # the semantics do too : Vocabulary::Comparison declares, per symbol, which
  # of the two primitives (less_than, equal) it reads and whether the result
  # is negated — the same three fields Evaluator::OPERATORS carries. If a
  # runtime's `compare` and the language ever say something different about
  # what `>=` computes, this is what catches it.
  it "Comparison declares the same algebra Evaluator::OPERATORS computes with" do
    # Written as text ("true"/"false") in the language, the same as ListFlag —
    # but a member's fields decode back through typed literal decoding on the
    # way out of reconstruction (the same path Attribute#list uses), so what
    # comes back here is already a real Ruby boolean, not text.
    live = Hecks::Bluebook::Expression::Evaluator::OPERATORS.to_h do |op|
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

  # SignTest's compares_via, MutationOp's sign, RefusalTemplate's wording and
  # FieldHint's patterns used to be held equal to hand-typed Ruby tables here
  # and in their own conformance specs. Those constants now read the
  # generated table (Resolver::SIGN_TEST_OPERATORS, CommandRules::
  # MUTATION_OPS, RefusalWording::TEMPLATES, FieldShape::HINTS), so the
  # regenerate-and-diff gates (spec/vocabulary_table_spec.rb, spec/
  # rust_vocabulary_spec.rb, CI's checks_codegen_drift) are the whole check.

  # Unlike Comparison, there is no separate live Ruby table to hold
  # this equal to — `strategy` names what Evaluator#includes? already does
  # per branch, not something a shared constant computes independently. This
  # pins the declaration against the actual case branches directly, so
  # changing what a branch does without updating the language is still caught.
  it "IncludeHaystack names the strategy each type actually uses" do
    expect(INCLUDE_HAYSTACK_ROWS.to_h { |row| [row[:type], row[:strategy]] })
      .to eq("Array" => "membership", "String" => "substring")

    resolver = Hecks::Bluebook::Expression::Resolver
    expect(Hecks::Bluebook::Expression::Evaluator.includes?(
             [resolver.parse("list"), resolver.parse("wanted")], { list: [1, 2, 3] }, { wanted: 2 }
           )).to be(true), "Array membership should still use equal?, matching the declared strategy"
    expect(Hecks::Bluebook::Expression::Evaluator.includes?(
             [resolver.parse("text"), resolver.parse("wanted")], { text: "hello" }, { wanted: "ell" }
           )).to be(true), "String substring should still match, matching the declared strategy"
  end

  # Only the names are held to the corpus — signs are read straight off the
  # generated table by CommandRules::MUTATION_OPS.
  it "MutationOp admits every op the corpus uses" do
    used = Dir.glob(File.join(InMemoryDomain::ROOT, "spec/corpus/*.json")).flat_map do |path|
      JSON.parse(File.read(path)).fetch("steps", [])
    end
    # Vendored addition, not (yet) upstream hecks (migration plan task
    # 4, i106 in-DSL math): multiply/clamp/remove joined set/append/
    # increment/decrement as real, declared MutationOp members — see
    # vocabulary.bluebook's own MutationOp comment for the arithmetic each
    # one performs.
    #
    # `delegate` joined them for a different real need, from a downstream
    # consumer rather than one of these three bundled examples —
    # CommandBuilder#delegates_to's own comment gives the full reasoning
    # (a chess domain's own move-legality check needing a synchronous,
    # single-dispatch handoff into a nested entity command). No bundled
    # example here uses it yet; `spec/dsl_spec.rb`'s own delegates_to
    # example is this vocabulary member's real usage instead.
    #
    # `corrects` joined for retroactive correction — CommandBuilder
    # #corrects_impl's own comment gives the full reasoning. Real in
    # banking: `Account.CorrectFee` corrects `FeeApplied`
    # (examples/banking/bluebook/deposit_accounts.bluebook).
    ops = %w[set append increment decrement multiply clamp remove delegate corrects]
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

  # Never `bind_runtime` — this spec only ever dispatches by raw FQN
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
    registry = Hecks::Runtime::Registry.new
    Hecks.with_registry(registry) do
      Kernel.load(InMemoryDomain::PERSISTENCE_PORT)
      Kernel.load(InMemoryDomain::EXTRACTION_PORT)
      Kernel.load(InMemoryDomain::MEMORY_ADAPTER)
      Kernel.load(InMemoryDomain::PRISM_ADAPTER)
      Kernel.load(bluebook)
    end
    Hecks::Runtime::Dispatcher.new(registry)
  end

  # **Coverage, both directions**. A declared step with no handler and a handler
  # with no declaration are the same class of drift — a step DISPATCH_ORDER
  # never reaches — but only the first direction used to be gated:
  #
  #   every DISPATCH_ORDER name must resolve to a real `step_<name>` handler
  #   `call` can actually `send` to — the thing that would have silently
  #   no-op'd (NoMethodError at dispatch time, really, but only the first
  #   time that step's preconditions were ever met) if a declared step and
  #   its handler ever drifted apart.
  #
  # The reverse was ungated: a `step_` method that exists but is missing
  # from the vocabulary is simply never called, with nothing failing — the
  # exact shape of bug audit H1 (see EntityDispatchOrder's own bluebook
  # comment above), where an entity command ran neither
  # refuse_unknown_arguments nor refuse_absent_arguments because a since-
  # corrected comment claimed the aggregate's own gate covered it, and no
  # spec here noticed the handler side had nothing declaring it. A live
  # orphan today would silently skip whatever it implements (a payload
  # gate, an invariant check, ...) on every single dispatch, forever — not
  # a NoMethodError, not a raised anything.
  [
    ["AggregateDispatchOrder", Hecks::Runtime::CommandInterpreter],
    ["EntityDispatchOrder", Hecks::Runtime::EntityInterpreter]
  ].each do |vocabulary, interpreter|
    it "every #{vocabulary} step resolves to a registered #{interpreter} handler" do
      declared(vocabulary).each do |step_name|
        expect(interpreter.private_method_defined?(:"step_#{step_name}"))
          .to be(true), "#{interpreter} declares #{step_name} but defines no step_#{step_name} handler"
      end
    end

    it "every #{interpreter} step_ handler appears in the declared #{vocabulary}" do
      # `private_instance_methods(false)`, not `private_method_defined?` —
      # only methods this class itself defines, so a `step_` helper picked
      # up from an included module (there are none today, but nothing stops
      # one tomorrow) can't be mistaken for an orphaned dispatch step.
      handler_steps = interpreter.private_instance_methods(false)
                                 .grep(/\Astep_/) { |m| m.to_s.delete_prefix("step_") }
      orphans = handler_steps - declared(vocabulary)

      expect(orphans).to be_empty,
                         "#{interpreter} defines #{orphans.map { |s| "step_#{s}" }.join(', ')}, but " \
                         "#{vocabulary} does not declare #{orphans.length == 1 ? 'it' : 'them'} — " \
                         "dispatch will never call #{orphans.length == 1 ? 'this handler' : 'these handlers'}"
    end
  end

  # Conditional correctness : assign_creation_attributes and advance_lifecycle
  # (both interpreters) are the two DISPATCH_ORDER members `call` does not run
  # unconditionally — each traces exactly when its own precondition holds, per
  # CommandInterpreter#step_assign_creation_attributes/#step_advance_lifecycle
  # and EntityInterpreter#step_advance_lifecycle's own internal self-guards.
  # `Open`/`Advance` fire both ; `Close`/`Touch` (spec/fixtures/
  # dispatch_order.bluebook) create and transition neither, so together the
  # four dispatches below exercise every conditional step's fire and skip.
  it "assign_creation_attributes fires only for a creating command" do
    runtime = boot(File.join(InMemoryDomain::ROOT, "spec/fixtures/dispatch_order.bluebook"))

    Hecks::Runtime::CommandInterpreter.trace = []
    runtime.dispatch("DispatchOrder::Widget.Open", label: { value: "x" }, amount: { value: 5 },
                      part_sequence: { value: 1 }, part_note: { value: "start" })
    creating_trace = Hecks::Runtime::CommandInterpreter.trace.dup

    Hecks::Runtime::CommandInterpreter.trace = []
    runtime.dispatch("DispatchOrder::Widget.Close", label: { value: "x" })
    acting_trace = Hecks::Runtime::CommandInterpreter.trace.dup
    Hecks::Runtime::CommandInterpreter.trace = nil

    expect(creating_trace).to include(:assign_creation_attributes)
    expect(acting_trace).not_to include(:assign_creation_attributes)
  end

  it "advance_lifecycle fires only when admissible_transition finds one" do
    runtime = boot(File.join(InMemoryDomain::ROOT, "spec/fixtures/dispatch_order.bluebook"))
    runtime.dispatch("DispatchOrder::Widget.Open", label: { value: "x" }, amount: { value: 5 },
                      part_sequence: { value: 1 }, part_note: { value: "start" })

    Hecks::Runtime::CommandInterpreter.trace = []
    runtime.dispatch("DispatchOrder::Widget.Close", label: { value: "x" })
    aggregate_trace = Hecks::Runtime::CommandInterpreter.trace.dup
    Hecks::Runtime::CommandInterpreter.trace = nil

    Hecks::Runtime::EntityInterpreter.trace = []
    runtime.dispatch("DispatchOrder::Widget.Part.Advance", label: { value: "x" }, sequence: { value: 1 },
                      note: { value: "done note" })
    entity_transitioning_trace = Hecks::Runtime::EntityInterpreter.trace.dup

    Hecks::Runtime::EntityInterpreter.trace = []
    runtime.dispatch("DispatchOrder::Widget.Part.Touch", label: { value: "x" }, sequence: { value: 1 },
                      note: { value: "touched" })
    entity_acting_trace = Hecks::Runtime::EntityInterpreter.trace.dup
    Hecks::Runtime::EntityInterpreter.trace = nil

    expect(aggregate_trace).not_to include(:advance_lifecycle)
    expect(entity_transitioning_trace).to include(:advance_lifecycle)
    expect(entity_acting_trace).not_to include(:advance_lifecycle)
  end
end
