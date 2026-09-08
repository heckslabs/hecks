require "spec_helper"
require "json"
require "hecks/fuzzing/bounded_exhaustive_expressions"
require_relative "support/ast_reader"

# EVERY RULE ROW CARRIES ITS STRUCTURED FORM, AND THAT FORM IS THE WHOLE
# MEANING.
#
# A `given`/`ensures`/invariant/precondition/policy `where` travels in
# the IR as `{description, canonical, ast}` (`Expression::AstJson.
# rule_row`) — `canonical` for anything that displays, `ast` for anything
# that evaluates. Before this, `ast` rode on value-object invariants
# alone and every other reader re-parsed the text with its own parser
# (`rust/codegen/src/expr/*`, `rust/host/src/expr_json.rs`, the Ruby
# runtime itself). This spec pins the contract those readers will move
# onto:
#
#   1. `ast` is present at every rule site, in every corpus chapter, and
#      is a pure function of `canonical`.
#   2. It is plain JSON: serialising and re-reading it is the identity,
#      byte-for-byte deterministic.
#   3. Its `"op"` tags are a CLOSED roster (`ExprAstJson::OPS`), and paths
#      are segment arrays, never dotted strings.
#   4. It carries the whole meaning: for every well-typed expression the
#      bounded-exhaustive generator can spell, reading the emitted `ast`
#      back into evaluator nodes and interpreting THOSE answers exactly
#      what interpreting the parsed text answers — same value, or the
#      same `EvaluationError`.
#   5. Emission is total: no generated expression makes `ExprAstJson` raise.
RSpec.describe "the structured expression AST every rule row carries" do
  ExprAstJson = Hecks::Bluebook::Expression::AstJson
  ExprAstEvaluator = Hecks::Bluebook::Expression::Evaluator
  ExprAstGenerator = Hecks::Fuzzing::BoundedExhaustiveExpressions

  CHAPTERS = {
    "Pizzas"     => "examples/pizzas/bluebook/pizzas.bluebook",
    "Banking"    => InMemoryDomain::BANKING_BLUEBOOK_DIR,
    # The one example whose policies carry a `where` (`by.value == "white"`).
    "Chess"      => "examples/chess/bluebook",
    "Expression" => "lib/hecks/grammar/expression.bluebook",
    "TillRoom"   => "spec/fixtures/till.bluebook",
    "Wire"       => "spec/fixtures/settlement.bluebook",
    "Reflex"     => "spec/fixtures/reflex.bluebook"
  }.freeze

  def load_chapter(file)
    registry = Hecks::Runtime::Registry.new
    Hecks.with_registry(registry) do
      Kernel.load(InMemoryDomain::PERSISTENCE_PORT)
      Kernel.load(InMemoryDomain::EXTRACTION_PORT)
      Kernel.load(InMemoryDomain::MEMORY_ADAPTER)
      Kernel.load(InMemoryDomain::PRISM_ADAPTER)
      load_bluebook_files(File.absolute_path(file, InMemoryDomain::ROOT))
    end
    registry
  end

  # Every `{description, canonical, ...}` row anywhere in an IR tree,
  # wherever the construct put it — found by shape, not by a list of
  # sites, so a new rule site is covered the day it emits.
  RULE_SITES = %i[givens ensures invariants preconditions].freeze

  def rule_rows(node, path = [])
    case node
    when Hash
      # A rule row sits directly inside one of the four rule lists; the
      # key test alone would also match the meta-domain's own `Rule`
      # value object wherever a mutation names its fields.
      own = RULE_SITES.include?(path[-2]) && node.key?(:canonical) ? [[path, node]] : []
      own + node.flat_map { |k, v| rule_rows(v, path + [k]) }
    when Array then node.each_with_index.flat_map { |v, i| rule_rows(v, path + [i]) }
    else []
    end
  end

  def ops_in(node)
    case node
    when Hash  then [node["op"]].compact + node.values.flat_map { |v| ops_in(v) }
    when Array then node.flat_map { |v| ops_in(v) }
    else []
    end
  end

  def paths_in(node)
    case node
    when Hash
      own = %w[lookup find].include?(node["op"]) ? [node["path"]] : []
      own + node.values.flat_map { |v| paths_in(v) }
    when Array then node.flat_map { |v| paths_in(v) }
    else []
    end
  end

  let(:irs) do
    loaded    = CHAPTERS.to_h { |name, file| [name, load_chapter(file).bluebook(name).to_h] }
    languages = %w[Bluebook World Hecksagon].to_h do |name|
      [name, Hecks::Bluebook::MetaValidator.grammar_registry.bluebook(name).to_h]
    end
    loaded.merge(languages)
  end

  it "carries `ast` on every rule row of every corpus chapter, derived from that row's own canonical" do
    rows = irs.flat_map { |name, ir| rule_rows(ir).map { |path, row| [name, path, row] } }
    expect(rows.size).to be > 100

    rows.each do |name, path, row|
      expect(row).to have_key(:ast), "#{name} #{path.join('.')} has no ast"
      expect(row[:ast]).to eq(ExprAstJson.emit_predicate(row[:canonical])),
                           "#{name} #{path.join('.')}: ast is not ExprAstJson.emit_predicate(canonical)"
    end
  end

  it "carries `where_ast` on every policy, nil exactly when there is no `where`" do
    policies = irs.flat_map { |name, ir| ir.fetch(:policies, []).map { |p| [name, p] } }
    expect(policies.count { |_, p| p[:where] }).to be > 0

    policies.each do |name, policy|
      expect(policy).to have_key(:where_ast), "#{name} policy #{policy[:name]} has no where_ast"
      expected = policy[:where] && ExprAstJson.emit_predicate(policy[:where])
      expect(policy[:where_ast]).to eq(expected), "#{name} policy #{policy[:name]}: where_ast disagrees with where"
    end
  end

  it "is plain, deterministic JSON" do
    irs.each_value do |ir|
      rule_rows(ir).map(&:last).each do |row|
        once  = JSON.generate(row[:ast])
        twice = JSON.generate(JSON.parse(once))
        expect(twice).to eq(once)
        expect(JSON.parse(once)).to eq(row[:ast])
      end
    end
  end

  it "uses only the closed op roster, with paths as segment arrays" do
    asts = irs.values.flat_map { |ir| rule_rows(ir).map { |_, row| row[:ast] } }
    expect(asts.flat_map { |ast| ops_in(ast) }.uniq - ExprAstJson::OPS).to be_empty

    segment = be_a(String).and(satisfy("be a non-empty, undotted segment") { |s| !s.empty? && !s.include?(".") })
    expect(asts.flat_map { |ast| paths_in(ast) }).to all(be_an(Array).and(all(segment)))
  end

  it "names every op the reader knows and no other — the roster is the reader's contract" do
    # The reader (spec/support/ast_reader.rb) mirrors ExprAstJson arm for arm;
    # an op that only one side knows is a drift between them.
    roster = ExprAstJson::OPS
    reader_ops = File.read(File.join(__dir__, "support/ast_reader.rb")).scan(/when "([a-z_]+)"/).flatten.uniq
    expect(reader_ops.sort).to eq(roster.sort)
  end

  it "carries the whole meaning: reading the ast back and interpreting it answers what the text answers" do
    state = ExprAstGenerator.synthetic_state
    attrs = ExprAstGenerator.synthetic_attrs

    outcome = lambda do |&block|
      { ok: block.call }
    rescue Hecks::Bluebook::Expression::EvaluationError => e
      { refused: e.message }
    end

    disagreements = ExprAstGenerator.all_predicates.filter_map do |expr|
      via_text = outcome.call { ExprAstEvaluator.call(expr, state, attrs) }
      via_ast  = outcome.call { ExprAstEvaluator.interpret(AstReader.read_predicate(ExprAstJson.emit_predicate(expr)), state, attrs) }
      [expr, via_text, via_ast] unless via_text == via_ast
    end

    expect(disagreements).to be_empty, "#{disagreements.size} expression(s) mean something different as ast:\n" +
                                       disagreements.first(10).map { |e, t, a| "  #{e}\n    text: #{t.inspect}\n    ast:  #{a.inspect}" }.join("\n")
  end

  it "emits an ast for every well-typed expression the bounded-exhaustive generator can spell" do
    crashes = ExprAstGenerator.all_predicates.filter_map do |expr|
      ExprAstJson.emit_predicate(expr)
      nil
    rescue StandardError => e
      [expr, e.class, e.message]
    end
    expect(crashes).to be_empty, crashes.first(10).inspect
  end
end
