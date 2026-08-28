require "spec_helper"
require "json"

# The grammar chapter's Operator domain, made load-bearing — BY CHECKING.
#
# lib/hecks/grammar/expression.bluebook has always declared what an
# operator IS: proposed until it reads in every target, admitted after,
# retired when withdrawn. Nothing read it — a content-management domain
# about operators, not the parser itself — and the evaluator's tables were
# free to drift from it (they did once, into DISJOINT sets — see
# vocabulary_conformance_spec's header for that story).
#
# This spec closes the gap at this project's honest claim level,
# agreement by checking: the admission ledger
# (lib/hecks/grammar/expression_operators.json) is replayed through
# the chapter's REAL commands — so every operator the evaluator runs
# passed a live Admit, through the "reads in every target" guard, on
# this very suite run — and the surviving admitted set is held equal to
# the hardcoded tables, both directions. An operator added to the
# evaluator without a ledger admission fails here; an admitted operator
# the evaluator does not implement fails here; a proposed or retired
# operator anywhere in a live table fails here, and that last line is
# the milestone's whole claim.
#
# By-CONSTRUCTION (the evaluator building its table from the chapter) is
# deliberately not attempted: the Prism adapter normalises every
# predicate through CanonicalForm while a bluebook loads, so the
# expression machinery cannot boot the chapter that would configure it —
# hence the checked-in projection (bin/expression_projection).
RSpec.describe "the operator domain" do
  ROOT_DIR = InMemoryDomain::ROOT
  LEDGER   = JSON.parse(File.read(File.join(ROOT_DIR, "lib/hecks/grammar/expression_operators.json"))).freeze
  CHAPTER  = File.join(ROOT_DIR, "lib/hecks/grammar/expression.bluebook")

  Evaluator     = Hecks::Bluebook::Expression::Evaluator
  Resolver      = Hecks::Bluebook::Expression::Resolver
  CanonicalForm = Hecks::Bluebook::Expression::CanonicalForm

  # The same boot corpus_spec proves — fresh registry, ports and adapters
  # loaded as data, the chapter itself, then a dispatcher over it. No
  # facade: the ledger dispatches by FQN, the same path MetaValidator
  # judges through.
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

  # Replayed ONCE for the whole file, refusals collected rather than
  # raised — a silently-refused Admit would shrink the admitted set and
  # surface as a confusing direction-B failure two examples later.
  DISPATCHER = boot_expression
  REFUSALS = LEDGER["steps"].filter_map do |step|
    begin
      DISPATCHER.dispatch(step["verb"], **symbolize(step["args"]))
      nil
    rescue *Hecks::Runtime::DOMAIN_REFUSALS => refusal
      "#{step['verb']} #{step['args']} — #{refusal.message}"
    end
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
    # ORDER included on purpose: grammar.md says declared order IS the
    # grammar (the first pattern that matches wins), and Memory#all
    # answers in insertion order, which is the ledger's Propose order.
    expect(symbols(admitted("comparison"))).to eq(Evaluator::COMPARISONS)
  end

  it "closes the triangle — the admitted comparisons are Vocabulary::Comparison's" do
    judged     = Hecks::Bluebook::MetaValidator.grammar_registry.bluebook("Bluebook")
    vocabulary = judged.aggregates.find { |a| a.name == "Vocabulary" }
    declared   = vocabulary.value_objects.find { |vo| vo.hecks_name == "Comparison" }
                           .members.map { |row| row.to_h.values.first }

    expect(symbols(admitted("comparison"))).to eq(declared)
  end

  # THE CLAIM MADE CHECKABLE: "order IS the grammar." `position` is
  # scoped per `grammar` (outer/inner each start
  # their own count at 1) and must be dense — a gap or a duplicate would
  # mean either a slot the parser skips or two operators claiming the same
  # turn, neither of which the ledger can represent honestly.
  def by_grammar(grammar) = ADMITTED.select { |op| op[:grammar].value == grammar }
                                    .sort_by { |op| op[:position].value }

  it "gives every grammar a dense, gap-free position — no skipped or doubled turn" do
    %w[outer inner].each do |grammar|
      positions = by_grammar(grammar).map { |op| op[:position].value }
      expect(positions).to eq((1..positions.size).to_a), "#{grammar} grammar positions: #{positions.inspect}"
    end
  end

  it "orders the outer grammar exactly the way grammar.md documents it" do
    # rule 1 (parenthesization) and rule 7 (bare-leaf fallback) are
    # structural, not operators — see the exclusion comment on the
    # aggregate itself. This is rules 2-6, in order.
    expect(symbols(by_grammar("outer"))).to eq(
      ["||", "&&", ".include?", ">=", "<=", "<", ">", "==", "!=", "!"]
    )
  end

  it "orders the inner grammar exactly the way grammar.md documents it" do
    # rule 1 (.length), 2-5 (literals), and 12 (dotted lookup) are
    # terminal productions, not operators — same exclusion. This is rules
    # 6-11, in order, followed by the eight vendored operators
    # (`.match?`/`.present?`/`.blank?`/`.split`/`.start_with?`/
    # `.end_with?`/`.first`/`.last`) admitted after grammar.md was
    # written — see this file's own header update for the finding that
    # sent them through the ledger for the first time.
    expect(symbols(by_grammar("inner"))).to eq(
      ["+", ".positive?", ".negative?", ".zero?", ".empty?", ".to_s", ".modulo", ".size", ".any?", ".none?", ".all?", ".find",
       ".match?", ".present?", ".blank?", ".split", ".start_with?", ".end_with?", ".first", ".last"]
    )
  end

  it "lets no proposed or retired operator into any live table" do
    # THE MILESTONE'S CLAIM. A proposed operator is not slower or gated —
    # it does not exist to the evaluator until the ledger admits it, and
    # a retired one stops existing the same way.
    unadmitted = symbols(OPERATORS.reject { |op| op[:status] == "admitted" })
    live       = Evaluator::COMPARISONS + PROBES.keys

    expect(live & unadmitted).to be_empty,
                                 "#{(live & unadmitted).inspect} run in a live table while the " \
                                 "chapter holds them proposed or retired — admit them in the " \
                                 "ledger or take them out of the machinery"
  end

  # The structural operators have no live constant — they ARE parse's
  # cases — so each is held by a behavioral probe, and direction B is
  # the probe table's keys equalling the admitted set.
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
    ".none?"       => -> { Resolver.parse("a.none? { |x| x }").then { |n| n.is_a?(Resolver::BlockPredicate) && n.mode == :none } },
    ".all?"        => -> { Resolver.parse("a.all? { |x| x }").then { |n| n.is_a?(Resolver::BlockPredicate) && n.mode == :all } },
    ".find"        => -> { Resolver.parse("a.find { |x| x }.b").is_a?(Resolver::Find) },
    ".match?"      => -> { Resolver.parse("a.match?(/x/)").is_a?(Resolver::MatchesRegex) },
    ".present?"    => -> { Resolver.parse("a.present?").is_a?(Resolver::Presence) && !Resolver.parse("a.present?").negated },
    ".blank?"      => -> { Resolver.parse("a.blank?").is_a?(Resolver::Presence) && Resolver.parse("a.blank?").negated },
    ".split"       => -> { Resolver.parse('a.split("x")').is_a?(Resolver::Split) },
    ".start_with?" => -> { Resolver.parse('a.start_with?("x")').is_a?(Resolver::StartsWith) },
    ".end_with?"   => -> { Resolver.parse('a.end_with?("x")').is_a?(Resolver::EndsWith) },
    ".first"       => -> { Resolver.parse("a.first").is_a?(Resolver::First) },
    ".last"        => -> { Resolver.parse("a.last").is_a?(Resolver::Last) }
  }.freeze

  it "implements every admitted structural operator, and no other" do
    structural = symbols(ADMITTED) - symbols(admitted("comparison"))

    expect(PROBES.keys.sort).to eq(structural.sort)
    PROBES.each do |symbol, probe|
      expect(probe.call).to be(true), "#{symbol} is admitted but the machinery no longer parses it"
    end
  end

  # THE GAP THIS FILE'S OWN HEADER NOW NAMES: everything above holds the
  # ledger equal to the evaluator's TABLES (COMPARISONS, PROBES) — but
  # eight real node types (MatchesRegex/Presence/Split/StartsWith/
  # EndsWith/First/Last, admitted above for the first time) used to
  # reach `resolver.rb` as hand-coded Structs with a parse branch and an
  # `interpret` arm and NOTHING ELSE — no ledger entry, no PROBES entry,
  # nothing any table-shaped guard could see, because they were never
  # table entries; they were leaf-grammar CODE. `operator_conformance_
  # spec` checking tables could not structurally notice code the tables
  # never mentioned.
  #
  # This closes it at the STRUCT level instead of the table level: every
  # Class Resolver/Evaluator actually define, found by REFLECTION
  # (`Module#constants`, not a hand-copied roster that could go stale
  # exactly the way the ledger itself did), must be either a documented
  # terminal/helper exclusion or point back to an admitted symbol via
  # `NODE_TYPE_FOR_SYMBOL`. A ninth operator vendored the same way — a
  # new Struct in resolver.rb, no ledger entry — fails HERE the moment
  # the struct exists, whether or not anyone remembers to touch this
  # file by hand.
  NODE_TYPE_FOR_SYMBOL = {
    "||" => Evaluator::Or, "&&" => Evaluator::And, "!" => Evaluator::Not, ".include?" => Evaluator::Include,
    # All six comparison symbols (`>=`/`<=`/`</`>`/`==`/`!=`) share one
    # node type — `Evaluator::Compare`, `operator:` naming which of the
    # six — the identical reduction `SignTest` already applies for
    # `.positive?`/`.negative?`/`.zero?` below. `COMPARISONS` (`==
    # OPERATORS.map(&:symbol)`) is the ledger-derived roster itself
    # (evaluator.rb), not a second hand-copied list of the six symbols.
    **Evaluator::COMPARISONS.to_h { |symbol| [symbol, Evaluator::Compare] },
    "+" => Resolver::Addition, ".modulo" => Resolver::Modulo,
    ".positive?" => Resolver::SignTest, ".negative?" => Resolver::SignTest, ".zero?" => Resolver::SignTest,
    ".empty?" => Resolver::Empty, ".to_s" => Resolver::ToS, ".size" => Resolver::Size,
    ".any?" => Resolver::BlockPredicate, ".none?" => Resolver::BlockPredicate, ".all?" => Resolver::BlockPredicate,
    ".find" => Resolver::Find,
    ".match?" => Resolver::MatchesRegex, ".present?" => Resolver::Presence, ".blank?" => Resolver::Presence,
    ".split" => Resolver::Split, ".start_with?" => Resolver::StartsWith, ".end_with?" => Resolver::EndsWith,
    ".first" => Resolver::First, ".last" => Resolver::Last
  }.freeze

  # Every real Class either module defines DIRECTLY (`false` — no
  # inherited constants), found mechanically rather than remembered.
  # `Struct.new(...)` returns a genuine anonymous `Class`, same as the
  # bare `NilLiteral = Class.new` (see its own comment in resolver.rb for
  # why that one isn't a Struct) — `.is_a?(Class)` catches both and
  # nothing else (the data-table constants beside them — `SIGN_TESTS`,
  # `BLOCK_PREDICATE_MODES`, `PROJECTION`, `OPERATORS`, ... — are
  # Array/Hash, never Class).
  def node_classes(mod) = mod.constants(false).map { |name| mod.const_get(name) }.grep(Class)

  # NOT AST nodes `parse` ever returns, excluded with the SAME reasoning
  # expression.bluebook's own "WHAT IS NOT HERE" comment on the
  # `Operator` aggregate already gives for the outer grammar's
  # parenthesization/bare-leaf-fallback rules and the inner grammar's
  # literal/dotted-lookup productions: nothing here has a per-target
  # rendering to admit.
  #   - literals + Lookup: a spelling that doesn't differ per target.
  #     `ArrayLiteral` joins them for the identical reason (`expr.rs`'s
  #     own `Expr::Array` is a LEAF, not routed through OperatorCategory).
  #   - `Evaluator::Resolve`: the boolean grammar's own "fall through to
  #     the leaf grammar" wrapper — structural, the same way the outer
  #     grammar's bare-leaf-fallback rule is, never itself a symbol.
  #   - `Evaluator::Operator`: a DATA shape (which comparison a `Compare`/
  #     `SignTest` node carries as its `op:`/`operator:` field), not a
  #     node `parse` ever returns on its own.
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

    # THE OTHER DIRECTION — `NODE_TYPE_FOR_SYMBOL` itself drifting (a
    # renamed or removed struct still named here) would silently defeat
    # the check above by inflating `covered` with a class reflection no
    # longer finds live.
    expect(covered - all_nodes).to be_empty
  end

  it "orders precedence the way the grammar checks" do
    # grammar.md: || binds loosest, then &&, then membership, then the
    # comparison tier, then !. Precedence rises with binding tightness.
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

    expect(declared).to eq(CanonicalForm::RULES.map { |rule| rule.to_h })
  end

  it "admits every operator the language itself stands on" do
    # THE SELF-BEARING SET, derived rather than remembered: every guard
    # and invariant in the language's own chapters evaluates through the
    # operator table this ledger admits, so retiring one of THOSE
    # operators would leave the language unable to read its own rules —
    # found the hard way, as a projection missing != that could not boot
    # the chapter to fix itself. bin/expression_projection refuses to
    # write such a projection; this is the same refusal, in-suite, ahead
    # of any regeneration.
    require "hecks/grammar"
    stranded = Hecks::Grammar.self_bearing_operators
                             .reject { |symbol, _| symbols(ADMITTED).include?(symbol) }

    expect(stranded).to be_empty,
                        stranded.map { |symbol, sites|
                          "#{symbol} is self-bearing (#{sites.first(2).join('; ')}) and not admitted"
                        }.join("\n")
  end

  describe "the gates, seen refusing" do
    it "refuses to admit an operator that does not read in every target" do
      throwaway = self.class.boot_expression
      throwaway.dispatch("Expression::Operator.Propose",
                         symbol: { value: "**" }, category: { value: "arithmetic" },
                         precedence: { value: 6 }, arity: { value: 2 },
                         grammar: { value: "inner" }, strategy: { value: "top_level_split" },
                         position: { value: 9 })

      expect { throwaway.dispatch("Expression::Operator.Admit", symbol: { value: "**" }) }
        .to raise_error(Hecks::Runtime::GivenNotMet,
                        /an operator must read in every target before it is admitted/)
    end

    it "refuses a rendering on a retired operator" do
      throwaway = self.class.boot_expression
      throwaway.dispatch("Expression::Operator.Propose",
                         symbol: { value: "**" }, category: { value: "arithmetic" },
                         precedence: { value: 6 }, arity: { value: 2 },
                         grammar: { value: "inner" }, strategy: { value: "top_level_split" },
                         position: { value: 9 })
      throwaway.dispatch("Expression::Operator.Render",
                         symbol: { value: "**" }, target: { value: "ruby" }, form: { value: "a ** b" })
      throwaway.dispatch("Expression::Operator.Admit",  symbol: { value: "**" })
      throwaway.dispatch("Expression::Operator.Retire", symbol: { value: "**" })

      expect do
        throwaway.dispatch("Expression::Operator.Render",
                           symbol: { value: "**" }, target: { value: "go" }, form: { value: "a ** b" })
      end.to raise_error(Hecks::Runtime::GivenNotMet, /a retired operator takes no new renderings/)
    end

    it "gives a spelling the ledger never admitted the ordinary unknown refusal" do
      # Not a slow operator, not a gated operator — NOT AN OPERATOR. The
      # refusal is the same one any unresolvable spelling gets; nothing
      # about the lifecycle invents a third wording.
      expect { Evaluator.call("a ** b", {}) }
        .to raise_error(Hecks::Bluebook::Expression::EvaluationError, /cannot resolve/)
    end
  end
end
