require "spec_helper"
require "json"
require "hecks/fuzzing/bounded_exhaustive_expressions"

# Every rule row carries `{description, canonical, ast}`: `canonical` for display,
# `ast` for evaluation. This spec pins the contract every reader of `ast` relies on.
RSpec.describe "the structured expression AST every rule row carries" do
  ExprAstJson = Hecks::Bluebook::Expression::AstJson
  ExprAstEvaluator = Hecks::Bluebook::Expression::Evaluator
  ExprAstGenerator = Hecks::Fuzzing::BoundedExhaustiveExpressions

  CHAPTERS = {
    "Pizzas"     => "examples/pizzas/bluebook/pizzas.bluebook",
    "Banking"    => InMemoryDomain::BANKING_BLUEBOOK_DIR,
    # The only example whose policies carry a `where`.
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

  # Rule rows are found by shape, not by a list of sites, so a new site is covered on day one.
  RULE_SITES = %i[givens ensures invariants preconditions].freeze

  def rule_rows(node, path = [])
    case node
    when Hash
      # The path check is needed: the key test alone also matches the meta-domain's `Rule`
      # value object.
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

  # Read-only in every example, so built once per file for speed.
  before(:context) do
    loaded    = CHAPTERS.to_h { |name, file| [name, load_chapter(file).bluebook(name).to_h] }
    languages = %w[Bluebook World Hecksagon].to_h do |name|
      [name, Hecks::Bluebook::MetaValidator.grammar_registry.bluebook(name).to_h]
    end
    @irs = loaded.merge(languages)
  end

  let(:irs) { @irs }

  it "carries `ast` on every rule row of every corpus chapter, derived from that row's own canonical" do
    rows = irs.flat_map { |name, ir| rule_rows(ir).map { |path, row| [name, path, row] } }
    expect(rows.size).to be > 100

    rows.each do |name, path, row|
      expect(row).to have_key(:ast), "#{name} #{path.join(".")} has no ast"
      expect(row[:ast]).to eq(ExprAstJson.emit_predicate(row[:canonical])),
                           "#{name} #{path.join(".")}: ast is not ExprAstJson.emit_predicate(canonical)"
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
    # The reader mirrors ExprAstJson arm for arm; an op only one side knows is drift.
    roster = ExprAstJson::OPS
    reader_ops = File.read(File.expand_path("../lib/hecks/bluebook/expression/ast_reader.rb",
                                            __dir__)).scan(/when "([a-z_]+)"/).flatten.uniq
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
      via_ast  = outcome.call do
        ExprAstEvaluator.interpret(Hecks::Bluebook::Expression::AstReader.read_predicate(ExprAstJson.emit_predicate(expr)),
                                   state, attrs)
      end
      [expr, via_text, via_ast] unless via_text == via_ast
    end

    expect(disagreements).to be_empty, "#{disagreements.size} expression(s) mean something different as ast:\n" +
                                       disagreements.first(10).map { |e, t, a|
                                         "  #{e}\n    text: #{t.inspect}\n    ast:  #{a.inspect}"
                                       }.join("\n")
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
