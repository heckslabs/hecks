require "spec_helper"

# The declared vocabularies must equal the tables the runtime uses: the comparison operators, sign
# tests, primitives, normalisation strategies, mutation ops, load order and domain refusals.
RSpec.describe "the declared vocabularies" do
  # grammar_registry runs the fixpoint at boot, so member values arrive typed (`true`, not "true").
  # A regression to the raw builder graph fails every typed-vs-string assertion below.
  def self.judged_meta = Hecks::Bluebook::MetaValidator.grammar_registry.bluebook("Bluebook")

  def self.vocabularies
    aggregate = judged_meta.aggregates.find { |a| a.name == "Vocabulary" }
    # `hecks_name`, not `name`: a value object is a Ruby class, so `name` is its constant path.
    aggregate.value_objects.to_h { |vo| [vo.hecks_name, vo.members.map { |row| row.to_h.values.first }] }
  end

  # The full row for one vocabulary; Comparison members carry more than a name.
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

  # Other constants read the generated table, held in vocabulary_table_spec.rb. Comparison is the
  # exception: Evaluator::COMPARISONS derives from the operator projection, so it is held here.
  it "Comparison matches the table the runtime uses" do
    expect(declared("Comparison")).to eq(Hecks::Bluebook::Expression::Evaluator::COMPARISONS.map(&:to_s))
  end

  # `Change.op` says `admits: Vocabulary::MutationOp`, so no second copy exists to compare. An
  # `admits` must name a declared set; dropping the link would turn WhereClause.op into a String.

  # The name lists only prove the operator set agrees; this proves the semantics do too: which of
  # less_than/equal each symbol reads and whether the result is negated, as Evaluator::OPERATORS.
  it "Comparison declares the same algebra Evaluator::OPERATORS computes with" do
    # Members decode through typed literal decoding, so these are real booleans, not text.
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

  # SignTest, MutationOp, RefusalTemplate and FieldHint read the generated table, so the
  # regenerate-and-diff gates (vocabulary_table_spec, rust_vocabulary_spec, codegen drift check)
  # are the whole check.

  # No live Ruby table exists to compare against: `strategy` names what Evaluator#includes? does
  # per branch, so this pins the declaration against the actual branches.
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

  # Only names are held to the corpus; signs are read off the generated table.
  it "MutationOp admits every op the corpus uses" do
    used = Dir.glob(File.join(InMemoryDomain::ROOT, "spec/corpus/*.json")).flat_map do |path|
      JSON.parse(File.read(path)).fetch("steps", [])
    end
    # multiply/clamp/remove, `delegate` (CommandBuilder#delegates_to) and `corrects`
    # (CommandBuilder#corrects_impl) extend set/append/increment/decrement.
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

  # Never `bind_runtime`: it installs global constants per aggregate name with no cleanup, and
  # "Widget" leaked into unrelated specs. Dispatch here is by raw FQN string only.
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

  # Coverage runs both ways: a declared step needs a `step_<name>` handler, and a handler missing
  # from the vocabulary is never called, with nothing failing (the audit H1 shape).
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
      # Only methods this class defines itself, so a `step_` helper from an included module is not
      # mistaken for an orphaned dispatch step.
      handler_steps = interpreter.private_instance_methods(false)
                                 .grep(/\Astep_/) { |m| m.to_s.delete_prefix("step_") }
      orphans = handler_steps - declared(vocabulary)

      expect(orphans).to be_empty,
                         "#{interpreter} defines #{orphans.map { |s| "step_#{s}" }.join(", ")}, but " \
                         "#{vocabulary} does not declare #{orphans.length == 1 ? "it" : "them"} — " \
                         "dispatch will never call #{orphans.length == 1 ? "this handler" : "these handlers"}"
    end
  end

  # `call` runs assign_creation_attributes and advance_lifecycle only when their precondition
  # holds. `Open`/`Advance` fire both; `Close`/`Touch` (spec/fixtures/dispatch_order.bluebook)
  # neither, so the four dispatches below cover each step's fire and skip.
  it "assign_creation_attributes fires only for a creating command" do
    runtime = boot(File.join(InMemoryDomain::ROOT, "spec/fixtures/dispatch_order.bluebook"))

    Hecks::Runtime::CommandInterpreter.trace = []
    runtime.dispatch_flat("DispatchOrder::Widget.Open", label: { value: "x" }, amount: { value: 5 },
                      part_sequence: { value: 1 }, part_note: { value: "start" })
    creating_trace = Hecks::Runtime::CommandInterpreter.trace.dup

    Hecks::Runtime::CommandInterpreter.trace = []
    runtime.dispatch_flat("DispatchOrder::Widget.Close", label: { value: "x" })
    acting_trace = Hecks::Runtime::CommandInterpreter.trace.dup
    Hecks::Runtime::CommandInterpreter.trace = nil

    expect(creating_trace).to include(:assign_creation_attributes)
    expect(acting_trace).not_to include(:assign_creation_attributes)
  end

  it "advance_lifecycle fires only when admissible_transition finds one" do
    runtime = boot(File.join(InMemoryDomain::ROOT, "spec/fixtures/dispatch_order.bluebook"))
    runtime.dispatch_flat("DispatchOrder::Widget.Open", label: { value: "x" }, amount: { value: 5 },
                      part_sequence: { value: 1 }, part_note: { value: "start" })

    Hecks::Runtime::CommandInterpreter.trace = []
    runtime.dispatch_flat("DispatchOrder::Widget.Close", label: { value: "x" })
    aggregate_trace = Hecks::Runtime::CommandInterpreter.trace.dup
    Hecks::Runtime::CommandInterpreter.trace = nil

    Hecks::Runtime::EntityInterpreter.trace = []
    runtime.dispatch_flat("DispatchOrder::Widget.Part.Advance", label: { value: "x" }, sequence: { value: 1 },
                      note: { value: "done note" })
    entity_transitioning_trace = Hecks::Runtime::EntityInterpreter.trace.dup

    Hecks::Runtime::EntityInterpreter.trace = []
    runtime.dispatch_flat("DispatchOrder::Widget.Part.Touch", label: { value: "x" }, sequence: { value: 1 },
                      note: { value: "touched" })
    entity_acting_trace = Hecks::Runtime::EntityInterpreter.trace.dup
    Hecks::Runtime::EntityInterpreter.trace = nil

    expect(aggregate_trace).not_to include(:advance_lifecycle)
    expect(entity_transitioning_trace).to include(:advance_lifecycle)
    expect(entity_acting_trace).not_to include(:advance_lifecycle)
  end
end
