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

  DISPATCH_ORDER_BLUEBOOK = File.join(InMemoryDomain::ROOT, "spec/fixtures/dispatch_order.bluebook").freeze
  OPEN_WIDGET = { label: { value: "x" }, amount: { value: 5 }, part_sequence: { value: 1 }, part_note: { value: "start" } }.freeze
  ARRAY_MEMBERSHIP = "Array membership should still use equal?, matching the declared strategy".freeze
  STRING_SUBSTRING = "String substring should still match, matching the declared strategy".freeze

  let(:dispatcher) { boot(DISPATCH_ORDER_BLUEBOOK) }
  let(:runtime) do
    dispatcher.tap { |booted| booted.dispatch_flat("DispatchOrder::Widget.Open", **OPEN_WIDGET) }
  end

  def declared(name)
    terms = VOCABULARIES.fetch(name)
    raise "vocabulary #{name} declares no members" if terms.empty?

    terms
  end

  # What Evaluator::OPERATORS computes with, by symbol. Members decode through typed literal
  # decoding, so these are real booleans, not text.
  def evaluator_algebra
    Hecks::Bluebook::Expression::Evaluator::OPERATORS.to_h do |op|
      [op.symbol, { compares_less_than: op.compares_less_than, compares_equal: op.compares_equal, negated: op.negated }]
    end
  end

  # One sentence for each Comparison row whose algebra differs from what the Evaluator computes.
  def algebra_disagreements(live)
    keys = %i[compares_less_than compares_equal negated]
    COMPARISON_ROWS.filter_map do |row|
      next if row.values_at(*keys) == live.fetch(row[:symbol]).values_at(*keys)

      "#{row[:symbol]} declares #{row.slice(*keys)}, Evaluator computes #{live.fetch(row[:symbol])}"
    end
  end

  # Whether the Evaluator's `includes?` finds `needle` in the `haystack` the expression `name` reads.
  def evaluator_includes?(name, haystack, needle)
    resolver = Hecks::Bluebook::Expression::Resolver
    Hecks::Bluebook::Expression::Evaluator.includes?([resolver.parse(name), resolver.parse("wanted")],
                                                     { name.to_sym => haystack }, { wanted: needle })
  end

  # The steps of every corpus script.
  def corpus_steps
    Dir.glob(File.join(InMemoryDomain::ROOT, "spec/corpus/*.json")).flat_map do |path|
      JSON.parse(File.read(path)).fetch("steps", [])
    end
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
  it "Comparison declares the same algebra Evaluator::OPERATORS computes with", :aggregate_failures do
    live = evaluator_algebra

    expect(COMPARISON_ROWS.map { |row| row[:symbol] }).to match_array(live.keys)
    expect(algebra_disagreements(live)).to be_empty
  end

  # SignTest, MutationOp, RefusalTemplate and FieldHint read the generated table, so the
  # regenerate-and-diff gates (vocabulary_table_spec, rust_vocabulary_spec, codegen drift check)
  # are the whole check.

  # No live Ruby table exists to compare against: `strategy` names what Evaluator#includes? does
  # per branch, so this pins the declaration against the actual branches.
  it "IncludeHaystack names the strategy each type actually uses", :aggregate_failures do
    strategies = INCLUDE_HAYSTACK_ROWS.to_h { |row| [row[:type], row[:strategy]] }

    expect(strategies).to eq("Array" => "membership", "String" => "substring")
    expect(evaluator_includes?("list", [1, 2, 3], 2)).to be(true), ARRAY_MEMBERSHIP
    expect(evaluator_includes?("text", "hello", "ell")).to be(true), STRING_SUBSTRING
  end

  # Only names are held to the corpus; signs are read off the generated table.
  it "MutationOp admits every op the corpus uses", :aggregate_failures do
    used = corpus_steps
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
      orphans = handler_steps(interpreter) - declared(vocabulary)

      expect(orphans).to be_empty, orphan_message(interpreter, vocabulary, orphans)
    end
  end

  # Only methods this class defines itself, so a `step_` helper from an included module is not
  # mistaken for an orphaned dispatch step.
  def handler_steps(interpreter)
    interpreter.private_instance_methods(false).grep(/\Astep_/) { |m| m.to_s.delete_prefix("step_") }
  end

  def orphan_message(interpreter, vocabulary, orphans)
    many = orphans.length != 1
    "#{interpreter} defines #{orphans.map { |s| "step_#{s}" }.join(", ")}, but " \
      "#{vocabulary} does not declare #{many ? "them" : "it"} — " \
      "dispatch will never call #{many ? "these handlers" : "this handler"}"
  end

  # The steps `interpreter` ran while the block dispatched.
  def traced(interpreter)
    interpreter.trace = []
    yield
    interpreter.trace.dup
  ensure
    interpreter.trace = nil
  end

  def part_args(note) = { label: { value: "x" }, sequence: { value: 1 }, note: { value: note } }

  # `call` runs assign_creation_attributes and advance_lifecycle only when their precondition
  # holds. `Open`/`Advance` fire both; `Close`/`Touch` (spec/fixtures/dispatch_order.bluebook)
  # neither, so the dispatches below cover each step's fire and skip.
  it "assign_creation_attributes fires only for a creating command", :aggregate_failures do
    command = Hecks::Runtime::CommandInterpreter
    creating = traced(command) { dispatcher.dispatch_flat("DispatchOrder::Widget.Open", **OPEN_WIDGET) }
    acting = traced(command) { dispatcher.dispatch_flat("DispatchOrder::Widget.Close", label: { value: "x" }) }

    expect(creating).to include(:assign_creation_attributes)
    expect(acting).not_to include(:assign_creation_attributes)
  end

  context "with a widget already opened" do
    # Opened before the trace starts, so the trace holds only the dispatch under test.
    before { runtime }

    it "skips advance_lifecycle for an aggregate command with no admissible transition" do
      trace = traced(Hecks::Runtime::CommandInterpreter) do
        runtime.dispatch_flat("DispatchOrder::Widget.Close", label: { value: "x" })
      end

      expect(trace).not_to include(:advance_lifecycle)
    end

    it "fires advance_lifecycle for an entity command that admits a transition" do
      trace = traced(Hecks::Runtime::EntityInterpreter) do
        runtime.dispatch_flat("DispatchOrder::Widget.Part.Advance", **part_args("done note"))
      end

      expect(trace).to include(:advance_lifecycle)
    end

    it "skips advance_lifecycle for an entity command that admits none" do
      trace = traced(Hecks::Runtime::EntityInterpreter) do
        runtime.dispatch_flat("DispatchOrder::Widget.Part.Touch", **part_args("touched"))
      end

      expect(trace).not_to include(:advance_lifecycle)
    end
  end
end
