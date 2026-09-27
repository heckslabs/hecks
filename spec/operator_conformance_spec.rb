require "spec_helper"
require "json"

# Replays the operator admission ledger (lib/hecks/grammar/expression_operators.json)
# through the expression chapter's real commands and holds the admitted set equal to the
# evaluator's tables, both directions. The evaluator cannot build its tables from the
# chapter itself (CanonicalForm runs while it loads), hence the checked-in projection.
RSpec.describe "the operator domain" do
  ROOT_DIR = InMemoryDomain::ROOT unless defined?(ROOT_DIR)
  LEDGER   = JSON.parse(File.read(File.join(ROOT_DIR, "lib/hecks/grammar/expression_operators.json"))).freeze
  CHAPTER  = File.join(ROOT_DIR, "lib/hecks/grammar/expression.bluebook")

  Evaluator     = Hecks::Bluebook::Expression::Evaluator
  Resolver      = Hecks::Bluebook::Expression::Resolver
  CanonicalForm = Hecks::Bluebook::Expression::CanonicalForm

  # Boots the chapter without a facade: the ledger dispatches by FQN, as MetaValidator does.
  def self.boot_expression
    registry = Hecks::Runtime::Registry.new
    Hecks.with_registry(registry) do
      Kernel.load(InMemoryDomain::PERSISTENCE_PORT)
      Kernel.load(InMemoryDomain::EXTRACTION_PORT)
      Kernel.load(InMemoryDomain::MEMORY_ADAPTER)
      Kernel.load(InMemoryDomain::PRISM_ADAPTER)
      Kernel.load(CHAPTER)
    end
    Hecks::Runtime::Dispatcher.new(registry)
  end

  def self.symbolize(value)
    case value
    when Hash  then value.to_h { |k, v| [k.to_sym, symbolize(v)] }
    when Array then value.map { |v| symbolize(v) }
    else value
    end
  end

  # Refusals are collected, not raised: a swallowed Admit would otherwise surface as a
  # confusing failure in a later example.
  DISPATCHER = boot_expression
  REFUSALS = LEDGER["steps"].filter_map do |step|
    DISPATCHER.dispatch_flat(step["verb"], **symbolize(step["args"]))
    nil
  rescue *Hecks::Runtime::DOMAIN_REFUSALS => e
    "#{step['verb']} #{step['args']} — #{e.message}"
  end.freeze

  def self.records(aggregate_name)
    registry  = DISPATCHER.registry
    aggregate = registry.bluebook("Expression").aggregate(aggregate_name)
    registry.repository("Expression", aggregate).all
  end

  OPERATORS = records("Operator").freeze
  ADMITTED  = OPERATORS.select { |op| op[:status] == "admitted" }.freeze
  RULES     = records("Normalisation").freeze

  def admitted(category) = ADMITTED.select { |op| op[:category].value == category }
  def symbols(ops)       = ops.map { |op| op[:symbol].value }

  it "replays the admission ledger without a single refusal" do
    expect(REFUSALS).to be_empty,
                        "the ledger refused — an operator was admitted without reading in every " \
                        "target, or a step no longer matches the chapter:\n  #{REFUSALS.join("\n  ")}"
  end

  it "admits exactly the comparison operators the evaluator runs, in check order" do
    # Order matters: the first matching pattern wins, and Memory#all answers in
    # insertion (Propose) order.
    expect(symbols(admitted("comparison"))).to eq(Evaluator::COMPARISONS)
  end

  it "closes the triangle — the admitted comparisons are Vocabulary::Comparison's" do
    judged     = Hecks::Bluebook::MetaValidator.grammar_registry.bluebook("Bluebook")
    vocabulary = judged.aggregates.find { |a| a.name == "Vocabulary" }
    declared   = vocabulary.value_objects.find { |vo| vo.hecks_name == "Comparison" }
                           .members.map { |row| row.to_h.values.first }

    expect(symbols(admitted("comparison"))).to eq(declared)
  end

  # `position` is scoped per grammar (outer and inner each count from 1) and must be
  # dense: a gap or duplicate would be a skipped slot or two operators sharing a turn.
  def by_grammar(grammar)
    ADMITTED.select { |op| op[:grammar].value == grammar }
            .sort_by { |op| op[:position].value }
  end

  it "gives every grammar a dense, gap-free position — no skipped or doubled turn" do
    %w[outer inner].each do |grammar|
      positions = by_grammar(grammar).map { |op| op[:position].value }
      expect(positions).to eq((1..positions.size).to_a), "#{grammar} grammar positions: #{positions.inspect}"
    end
  end

  it "orders the outer grammar exactly the way grammar.md documents it" do
    # Rules 2-6; rule 1 (parenthesization) and rule 7 (bare-leaf fallback) are structural.
    expect(symbols(by_grammar("outer"))).to eq(
      ["||", "&&", ".include?", ">=", "<=", "<", ">", "==", "!=", "!"]
    )
  end

  it "orders the inner grammar exactly the way grammar.md documents it" do
    # Rules 6-11, then the operators admitted after grammar.md was written; rules 1
    # (.length), 2-5 (literals) and 12 (dotted lookup) are terminals, not operators.
    expect(symbols(by_grammar("inner"))).to eq(
      ["+", ".positive?", ".negative?", ".zero?", ".empty?", ".to_s", ".modulo", ".size", ".any?", ".none?", ".all?", ".find",
       ".match?", ".present?", ".blank?", ".split", ".start_with?", ".end_with?", ".first", ".last", ".set?", ".unset?"]
    )
  end

  it "lets no proposed or retired operator into any live table" do
    # A proposed or retired operator does not exist to the evaluator at all.
    unadmitted = symbols(OPERATORS.reject { |op| op[:status] == "admitted" })
    live       = Evaluator::COMPARISONS + PROBES.keys

    expect(live & unadmitted).to be_empty,
                                 "#{(live & unadmitted).inspect} run in a live table while the " \
                                 "chapter holds them proposed or retired — admit them in the " \
                                 "ledger or take them out of the machinery"
  end

  # Structural operators have no live constant (they are parse's cases), so each is
  # held by a behavioral probe; the probe keys must equal the admitted set.
  PROBES = {
    "||"           => -> { Evaluator.parse("a || b").is_a?(Evaluator::Or) },
    "&&"           => -> { Evaluator.parse("a && b").is_a?(Evaluator::And) },
    "!"            => -> { Evaluator.parse("!a").is_a?(Evaluator::Not) },
    ".include?"    => -> { Evaluator.parse("list.include?(x)").is_a?(Evaluator::Include) },
    "+"            => -> { Resolver.parse("a + b").is_a?(Resolver::Addition) },
    ".modulo"      => -> { Resolver.parse("a.modulo(b)").is_a?(Resolver::Modulo) },
    ".positive?"   => -> { Resolver.parse("a.positive?").is_a?(Resolver::SignTest) },
    ".negative?"   => -> { Resolver.parse("a.negative?").is_a?(Resolver::SignTest) },
    ".zero?"       => -> { Resolver.parse("a.zero?").is_a?(Resolver::SignTest) },
    ".empty?"      => -> { Resolver.parse("a.empty?").is_a?(Resolver::Empty) },
    ".to_s"        => -> { Resolver.parse("a.to_s").is_a?(Resolver::ToS) },
    ".size"        => -> { Resolver.parse("a.size").is_a?(Resolver::Size) },
    ".any?"        => -> { Resolver.parse("a.any? { |x| x }").then { |n| n.is_a?(Resolver::BlockPredicate) && n.mode == :any } },
    ".none?"       => lambda {
      Resolver.parse("a.none? { |x| x }").then do |n|
        n.is_a?(Resolver::BlockPredicate) && n.mode == :none
      end
    },
    ".all?"        => -> { Resolver.parse("a.all? { |x| x }").then { |n| n.is_a?(Resolver::BlockPredicate) && n.mode == :all } },
    ".find"        => -> { Resolver.parse("a.find { |x| x }.b").is_a?(Resolver::Find) },
    ".match?"      => -> { Resolver.parse("a.match?(/x/)").is_a?(Resolver::MatchesRegex) },
    ".present?"    => -> { Resolver.parse("a.present?").is_a?(Resolver::Presence) && !Resolver.parse("a.present?").negated },
    ".blank?"      => -> { Resolver.parse("a.blank?").is_a?(Resolver::Presence) && Resolver.parse("a.blank?").negated },
    ".split"       => -> { Resolver.parse('a.split("x")').is_a?(Resolver::Split) },
    ".start_with?" => -> { Resolver.parse('a.start_with?("x")').is_a?(Resolver::StartsWith) },
    ".end_with?"   => -> { Resolver.parse('a.end_with?("x")').is_a?(Resolver::EndsWith) },
    ".first"       => -> { Resolver.parse("a.first").is_a?(Resolver::First) },
    ".last"        => -> { Resolver.parse("a.last").is_a?(Resolver::Last) },
    ".set?"        => -> { Resolver.parse("a.set?").is_a?(Resolver::Assignment) && !Resolver.parse("a.set?").negated },
    ".unset?"      => -> { Resolver.parse("a.unset?").is_a?(Resolver::Assignment) && Resolver.parse("a.unset?").negated }
  }.freeze

  it "implements every admitted structural operator, and no other" do
    structural = symbols(ADMITTED) - symbols(admitted("comparison"))

    expect(PROBES.keys.sort).to eq(structural.sort)
    PROBES.each do |symbol, probe|
      expect(probe.call).to be(true), "#{symbol} is admitted but the machinery no longer parses it"
    end
  end

  # Table checks cannot see a node type that never had a table entry. Every Class that
  # Resolver/Evaluator define (found by reflection) must be a listed terminal or map
  # back to an admitted symbol here, so a new Struct with no ledger entry fails.
  NODE_TYPE_FOR_SYMBOL = {
    "||" => Evaluator::Or, "&&" => Evaluator::And, "!" => Evaluator::Not, ".include?" => Evaluator::Include,
    # All six comparison symbols share one node type, Evaluator::Compare.
    **Evaluator::COMPARISONS.to_h { |symbol| [symbol, Evaluator::Compare] },
    "+" => Resolver::Addition, ".modulo" => Resolver::Modulo,
    ".positive?" => Resolver::SignTest, ".negative?" => Resolver::SignTest, ".zero?" => Resolver::SignTest,
    ".empty?" => Resolver::Empty, ".to_s" => Resolver::ToS, ".size" => Resolver::Size,
    ".any?" => Resolver::BlockPredicate, ".none?" => Resolver::BlockPredicate, ".all?" => Resolver::BlockPredicate,
    ".find" => Resolver::Find,
    ".match?" => Resolver::MatchesRegex, ".present?" => Resolver::Presence, ".blank?" => Resolver::Presence,
    ".split" => Resolver::Split, ".start_with?" => Resolver::StartsWith, ".end_with?" => Resolver::EndsWith,
    ".first" => Resolver::First, ".last" => Resolver::Last,
    ".set?" => Resolver::Assignment, ".unset?" => Resolver::Assignment
  }.freeze

  # Classes each module defines directly; Struct.new and Class.new both yield a Class,
  # while the data-table constants are Array/Hash.
  def node_classes(mod) = mod.constants(false).map { |name| mod.const_get(name) }.grep(Class)

  # Terminals and helpers with no per-target rendering to admit:
  # literals and Lookup (spelled the same in every target), Evaluator::Resolve (the
  # fall-through wrapper), and Evaluator::Operator (a data shape carried by Compare/SignTest).
  NON_OPERATOR_NODE_TYPES = [
    Resolver::IntegerLiteral, Resolver::FloatLiteral, Resolver::StringLiteral, Resolver::BoolLiteral,
    Resolver::NilLiteral, Resolver::ArrayLiteral, Resolver::Lookup,
    Evaluator::Resolve, Evaluator::Operator
  ].freeze

  it "gives every non-terminal Resolver/Evaluator node type an admitted ledger symbol" do
    all_nodes      = (node_classes(Evaluator) + node_classes(Resolver)).uniq
    operator_nodes = all_nodes - NON_OPERATOR_NODE_TYPES
    covered        = NODE_TYPE_FOR_SYMBOL.values_at(*symbols(ADMITTED)).compact.uniq

    stranded = operator_nodes - covered
    expect(stranded).to be_empty,
                        "#{stranded.map(&:name).inspect} — a real AST node type with " \
                        "no admitted ledger symbol pointing at it. Either it's a genuine terminal/" \
                        "structural production (add it to NON_OPERATOR_NODE_TYPES, the same reasoning " \
                        "grammar.md's own exclusions use) or it bypassed Propose/Render/Admit the way " \
                        "eight vendored operators did (see this file's own header) — admit it in the " \
                        "ledger, add its symbol to NODE_TYPE_FOR_SYMBOL and a PROBES entry, instead."

    # A stale NODE_TYPE_FOR_SYMBOL entry would inflate `covered` and defeat the check above.
    expect(covered - all_nodes).to be_empty
  end

  it "orders precedence the way the grammar checks" do
    # Precedence rises with binding tightness: ||, &&, membership, comparison, then !.
    tiers = ["||", "&&", ".include?", ">=", "!"].map do |symbol|
      ADMITTED.find { |op| op[:symbol].value == symbol }[:precedence].value
    end
    expect(tiers).to eq(tiers.sort)
    expect(tiers.uniq).to eq(tiers)

    expect(Evaluator.parse("a || b && c")).to be_a(Evaluator::Or)
  end

  it "renders every admitted operator in ruby — the guard's claim, strengthened" do
    ADMITTED.each do |op|
      targets = Array(op[:renderings]).map { |rendering| rendering[:target] }
      expect(targets).to include("ruby"),
                         "#{op[:symbol].value} was admitted reading in #{targets.inspect} — " \
                         "every target means ruby, at minimum"
    end
  end

  it "admits exactly the normalisation rules canonical form applies, field for field" do
    admitted_rules = RULES.select { |rule| rule[:status] == "admitted" }.sort_by { |rule| rule[:position].value }
    read_back = admitted_rules.map do |rule|
      { strategy: rule[:strategy].value, source_token: rule[:source_token].value,
        replacement: rule[:replacement].value, boundary: rule[:boundary].value,
        position: rule[:position].value.to_s }
    end

    expect(read_back).to eq(CanonicalForm.table)
  end

  it "keeps the chapter's own Rule set equal to the live rules — no third copy" do
    declared = DISPATCHER.registry.bluebook("Expression").aggregate("Normalisation")
                         .value_object("Rule").members.map(&:to_h)

    expect(declared).to eq(CanonicalForm::RULES.map(&:to_h))
  end

  it "admits every operator the language itself stands on" do
    # Guards and invariants in the language's own chapters evaluate through this operator
    # table, so retiring one would leave the language unable to read its rules.
    # bin/expression_projection refuses the same case at regeneration.
    require "hecks/grammar"
    stranded = Hecks::Grammar.self_bearing_operators
                             .except(*symbols(ADMITTED))

    expect(stranded).to be_empty,
                        stranded.map { |symbol, sites|
                          "#{symbol} is self-bearing (#{sites.first(2).join('; ')}) and not admitted"
                        }.join("\n")
  end

  describe "the gates, seen refusing" do
    it "refuses to admit an operator that does not read in every target" do
      throwaway = self.class.boot_expression
      throwaway.dispatch_flat("Expression::Operator.Propose",
                              symbol: { value: "**" }, category: { value: "arithmetic" },
                              precedence: { value: 6 }, arity: { value: 2 },
                              grammar: { value: "inner" }, strategy: { value: "top_level_split" },
                              position: { value: 9 })

      expect { throwaway.dispatch_flat("Expression::Operator.Admit", symbol: { value: "**" }) }
        .to raise_error(Hecks::Runtime::GivenNotMet,
                        /an operator must read in every target before it is admitted/)
    end

    it "refuses a rendering on a retired operator" do
      throwaway = self.class.boot_expression
      throwaway.dispatch_flat("Expression::Operator.Propose",
                              symbol: { value: "**" }, category: { value: "arithmetic" },
                              precedence: { value: 6 }, arity: { value: 2 },
                              grammar: { value: "inner" }, strategy: { value: "top_level_split" },
                              position: { value: 9 })
      throwaway.dispatch_flat("Expression::Operator.Render",
                              symbol: { value: "**" }, target: { value: "ruby" }, form: { value: "a ** b" })
      throwaway.dispatch_flat("Expression::Operator.Admit",  symbol: { value: "**" })
      throwaway.dispatch_flat("Expression::Operator.Retire", symbol: { value: "**" })

      expect do
        throwaway.dispatch_flat("Expression::Operator.Render",
                                symbol: { value: "**" }, target: { value: "go" }, form: { value: "a ** b" })
      end.to raise_error(Hecks::Runtime::GivenNotMet, /a retired operator takes no new renderings/)
    end

    it "gives a spelling the ledger never admitted the ordinary unknown refusal" do
      # An unadmitted spelling gets the same refusal as any unresolvable one.
      expect { Evaluator.call("a ** b", {}) }
        .to raise_error(Hecks::Bluebook::Expression::EvaluationError, /cannot resolve/)
    end
  end
end
