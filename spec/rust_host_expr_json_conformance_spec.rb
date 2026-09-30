require "json"
require "open3"

# Differential test of rust/host's `expr_json` (the mint-time invariant interpreter) against
# Ruby's own `Evaluator`/`Resolver`: each expression is parsed once by Ruby, emitted as the
# `ast` JSON `ir.json` carries, then interpreted by both, and the two must give the same value
# or the same refusal, word for word.
#
# Value objects here are Ruby Hashes, so the cases keep to what a Hash and a value object share:
# no one-field nested object (Ruby unwraps a value object, not a Hash) and no `size`, `empty?`,
# `first` or `last` of a multi-field object.
RSpec.describe "Rust/Ruby expression parity (rust/host expr_json)", :io do
  EXPR_HARNESS_HOST_DIR = File.expand_path("../rust/host", __dir__)

  # A case is [kind, expression text, state]; `:leaf` runs `Resolver`, `:rule` runs `Evaluator`.
  EXPR_PARITY_CASES = [
    # addition
    [:leaf, "1 + 2", {}],
    [:leaf, "2 + 1.5", {}],
    [:leaf, "a + 1", { "a" => 9 }],
    [:leaf, "9223372036854775807 + 1", {}],
    [:leaf, "a + b", { "a" => 1.7e308, "b" => 1.7e308 }],
    [:leaf, "a + 1", { "a" => nil }],
    [:leaf, "a + 1", { "a" => "x" }],
    [:leaf, "1 + a", { "a" => [1, "b"] }],
    # modulo
    [:leaf, "7.modulo(3)", {}],
    [:leaf, "-7.modulo(3)", {}],
    [:leaf, "7.modulo(-3)", {}],
    [:leaf, "5.5.modulo(2)", {}],
    [:leaf, "a.modulo(b)", { "a" => 7, "b" => -2.5 }],
    [:leaf, "a.modulo(b)", { "a" => -1.0, "b" => 2 }],
    [:leaf, "7.modulo(0)", {}],
    [:leaf, "a.modulo(0.0)", { "a" => 7 }],
    [:leaf, "a.modulo(2)", { "a" => nil }],
    [:leaf, "a.modulo(2)", { "a" => "x" }],
    # include
    [:rule, 'tags.include?("b")', { "tags" => %w[a b] }],
    [:rule, 'tags.include?("z")', { "tags" => %w[a b] }],
    [:rule, '!tags.include?("z")', { "tags" => %w[a b] }],
    [:rule, "n.include?(2.0)", { "n" => [1, 2] }],
    [:rule, "n.include?(m)", { "n" => [1, nil], "m" => nil }],
    [:rule, 's.include?("ell")', { "s" => "hello" }],
    [:rule, 's.include?("")', { "s" => "hello" }],
    [:rule, 's.include?("a")', { "s" => nil }],
    [:rule, 's.include?("a")', { "s" => 5 }],
    [:rule, "s.include?(1)", { "s" => "abc" }],
    [:rule, "s.include?(n)", { "s" => "abc", "n" => nil }],
    [:rule, 'x.include?("a")', { "x" => [["a"], "a"] }],
    [:rule, '["a", "b"].include?(x)', { "x" => "b" }],
    [:rule, "n.include?(nil)", { "n" => [1, nil] }],
    [:rule, "a == 1 || b == 2", { "a" => 0, "b" => 2 }],
    [:rule, "[1, 2].include?(x)", { "x" => 2.0 }],
    # array literals, first, last
    [:leaf, '[1, 2.5, "a"]', {}],
    [:leaf, "[]", {}],
    [:leaf, "[a, b + 1]", { "a" => nil, "b" => 1 }],
    [:leaf, "[1, 2].first", {}],
    [:leaf, "[1, 2].last", {}],
    [:leaf, "[].first", {}],
    [:leaf, "x.first", { "x" => [7, 8] }],
    [:leaf, "x.last", { "x" => [7, 8] }],
    [:leaf, "x.last", { "x" => [] }],
    [:leaf, "x.first", { "x" => "abc" }],
    [:leaf, "x.last", { "x" => nil }],
    [:leaf, "x.first", { "x" => 5 }],
    # match?
    [:leaf, "x.match?(/^b$/)", { "x" => "a\nb" }],
    [:leaf, 'x.match?(/\Ab\z/)', { "x" => "a\nb" }],
    [:leaf, "x.match?(/a.b/)", { "x" => "a\nb" }],
    [:leaf, "x.match?(/a.b/m)", { "x" => "a\nb" }],
    [:leaf, "x.match?(/A/i)", { "x" => "a" }],
    [:leaf, 'x.match?(/\d/)', { "x" => "٣" }],
    [:leaf, 'x.match?(/\d/)', { "x" => "5" }],
    [:leaf, 'x.match?(/\A[\w.]+\z/)', { "x" => "a.b_c" }],
    [:leaf, 'x.match?(/\A[\D]+\z/)', { "x" => "ab" }],
    [:leaf, 'x.match?(/\A\h+\z/)', { "x" => "beef" }],
    [:leaf, "x.match?(/a b/x)", { "x" => "ab" }],
    [:leaf, 'x.match?(/\Aa\Z/)', { "x" => "a\n" }],
    [:leaf, 'x.match?(/\A[0-9.]+\z/)', { "x" => 12 }],
    [:leaf, 'x.match?(/\A[0-9.]+\z/)', { "x" => 1.5 }],
    [:leaf, 'x.match?(/\A\z/)', { "x" => nil }],
    [:leaf, "x.match?(/a/)", { "x" => true }],
    [:leaf, "x.match?(/a/)", { "x" => false }],
    [:leaf, "x.match?(/a/)", { "x" => [1] }],
    [:leaf, "x.match?(/(/)", { "x" => "a" }],
    # presence, set?; a non-empty list that is not pairs (`[0]`) is present in both hosts.
    *[nil, false, "", [], " ", 0, true, [[1, 2]], [0], [1, 2]].flat_map do |value|
      [[:leaf, "x.present?", { "x" => value }], [:leaf, "x.blank?", { "x" => value }],
       [:leaf, "x.set?", { "x" => value }], [:leaf, "x.unset?", { "x" => value }]]
    end,
    # split, start_with?, end_with?
    [:leaf, 'x.split(" ")', { "x" => "  a b  c " }],
    [:leaf, 'x.split("")', { "x" => "aé" }],
    [:leaf, 'x.split(",")', { "x" => "a,b,," }],
    [:leaf, 'x.split(",")', { "x" => ",a" }],
    [:leaf, 'x.split(",")', { "x" => "" }],
    [:leaf, 'x.split(",")', { "x" => 5 }],
    [:leaf, 'x.split(",")', { "x" => nil }],
    [:leaf, 'x.split(",").last', { "x" => "a,b" }],
    [:leaf, 'x.start_with?("ab")', { "x" => "abc" }],
    [:leaf, 'x.end_with?("bc")', { "x" => "abc" }],
    [:leaf, 'x.end_with?("bc")', { "x" => "abd" }],
    [:leaf, 'x.start_with?("a")', { "x" => nil }],
    [:leaf, 'x.end_with?("a")', { "x" => [1] }],
    # block predicates
    [:leaf, "seats.any? { |s| s.taken == false }",
     { "seats" => [{ "n" => 1, "taken" => true }, { "n" => 2, "taken" => false }] }],
    [:leaf, "seats.all? { |s| s.taken == false }",
     { "seats" => [{ "n" => 1, "taken" => true }, { "n" => 2, "taken" => false }] }],
    [:leaf, "seats.none? { |s| s.taken == false }",
     { "seats" => [{ "n" => 1, "taken" => true }, { "n" => 2, "taken" => false }] }],
    [:leaf, "seats.all? { |s| s.taken == false }", { "seats" => [] }],
    [:leaf, "seats.any? { |s| s.taken == false }", { "seats" => [] }],
    [:leaf, "seats.none? { |s| s.taken == false }", { "seats" => [] }],
    [:leaf, "x.any? { |y| y == 1 }", { "x" => 5 }],
    [:leaf, "x.all? { |y| y == 1 }", { "x" => nil }],
    [:leaf, "x.none? { |y| y == 1 }", { "x" => "abc" }],
    [:leaf, "xs.all? { |x| x.positive? }", { "xs" => [-1, "a"] }],
    [:leaf, "xs.any? { |x| x.positive? }", { "xs" => [1, "a"] }],
    [:leaf, "xs.any? { |n| n == 2 && m == 9 }", { "xs" => [1, 2], "m" => 9, "n" => 100 }],
    [:leaf, "xs.any? { |n| n == 2 && m == 9 }", { "xs" => [1, 2], "m" => 8 }],
    [:leaf, "xs.any? { |s| xs.none? { |o| o == s + 1 } }", { "xs" => [1, 2, 4] }],
    [:leaf, "xs.any? { |x| ghost }", { "xs" => [1] }],
    [:leaf, "xs.any? { |x| x.include?(\"a\") }", { "xs" => %w[a b] }],
    [:leaf, "xs.all? { |x| x.present? }", { "xs" => ["a", ""] }],
    # find
    [:leaf, "legs.find { |l| l.open == true }.to",
     { "legs" => [{ "to" => "A", "open" => false }, { "to" => "B", "open" => true }] }],
    [:leaf, "legs.find { |l| l.open == true }.nope", { "legs" => [{ "to" => "A", "open" => true }] }],
    [:leaf, "legs.find { |l| l.open == true }.to", { "legs" => [{ "to" => "A", "open" => false }] }],
    [:leaf, "legs.find { |l| l.open == true }.to", { "legs" => [] }],
    [:leaf, "legs.find { |l| l.open == true }", { "legs" => [{ "to" => "A", "open" => true }] }],
    [:leaf, "xs.find { |x| x.positive? }", { "xs" => [3, "a"] }],
    [:leaf, "xs.find { |x| x.positive? }", { "xs" => [-3, "a"] }],
    [:leaf, "x.find { |y| y == 1 }", { "x" => "abc" }],
    [:leaf, "x.find { |y| y == 1 }", { "x" => nil }],
    # paths
    [:leaf, "x.foo", { "x" => "abcfoo" }],
    [:leaf, "x.nil?", { "x" => "abc" }],
    [:leaf, "x.a", { "x" => 1.5 }],
    [:leaf, "x.a", { "x" => true }],
    [:leaf, "x.a", { "x" => nil }],
    [:leaf, "x.a", { "x" => [1] }],
    [:leaf, "x.a", { "x" => 5 }],
    [:leaf, "x.b", { "x" => { "a" => 1, "b" => 2 } }],
    [:leaf, "x.c", { "x" => { "a" => 1, "b" => 2 } }],
    [:leaf, "ghost", {}],
    # wording of the operators Rust already had
    [:leaf, "x.size", { "x" => 5 }],
    [:leaf, "x.empty?", { "x" => nil }],
    [:leaf, "x.to_s", { "x" => [1, "a"] }],
    [:leaf, "x.to_s", { "x" => { "a" => 1, "b" => "c" } }],
    [:rule, "x < 1", { "x" => "a" }],
    [:rule, "x < y", { "x" => nil, "y" => [1] }],
    [:rule, "x.zero?", { "x" => "a" }],
    [:rule, "x.positive?", { "x" => nil }],
    [:rule, "x == 1", { "x" => 1.0 }],
    [:rule, "x == y", { "x" => [1], "y" => [1.0] }],
    # floats print as Ruby prints them
    *[3.0, 0.5, -0.0, 1e14, 999_999_999_999_999.9, 1e15, 1.5e15, 1e20, 0.0001, 0.00001, 1.5e-7,
      123_456_789.123456789].map { |f| [:leaf, "x.to_s", { "x" => f }] }
  ].freeze

  def self.cargo? = system("cargo", "--version", out: File::NULL, err: File::NULL)

  # Built once per suite run and memoized, failures included, as the lineage spec builds its own.
  def self.harness_binary
    @harness_binary ||= build_harness
    raise @harness_binary if @harness_binary.is_a?(Exception)

    @harness_binary
  end

  def self.build_harness
    _stdout, stderr, status = Open3.capture3("cargo", "build", "--bin", "expr_harness", chdir: EXPR_HARNESS_HOST_DIR)
    binary = File.join(EXPR_HARNESS_HOST_DIR, "target", "debug", "expr_harness")
    return binary if status.success? && File.executable?(binary)

    RuntimeError.new("`cargo build --bin expr_harness` failed in #{EXPR_HARNESS_HOST_DIR}:\n#{stderr}")
  end

  before(:all) { skip "no cargo on PATH" unless self.class.cargo? }

  # Ruby's own answer as JSON-shaped data, plus the `ast` the Rust host is handed.
  def ruby_answer(kind, text, state)
    symbolized = JSON.parse(JSON.generate(state), symbolize_names: true)
    if kind == :rule
      node = Hecks::Bluebook::Expression::Evaluator.parse(text)
      ast = Hecks::Bluebook::Expression::AstJson.emit_bool(node)
      value = Hecks::Bluebook::Expression::Evaluator.interpret(node, symbolized, {})
    else
      node = Hecks::Bluebook::Expression::Resolver.parse(text)
      ast = Hecks::Bluebook::Expression::AstJson.emit_resolver(node)
      value = Hecks::Bluebook::Expression::Resolver.interpret(node, symbolized, {})
    end
    [ast, { "ok" => JSON.parse(JSON.generate([value])).first }]
  rescue Hecks::Bluebook::Expression::EvaluationError => e
    [ast, { "error" => e.message }]
  end

  # The regex engines word a malformed pattern differently; only the prefix is shared.
  def comparable(answer)
    return answer unless answer["error"]&.start_with?("match? given an invalid pattern")

    { "error" => answer["error"].split(" — ").first }
  end

  it "answers every expression the way Ruby's interpreters do, value for value and refusal for refusal" do
    prepared = EXPR_PARITY_CASES.map do |kind, text, state|
      ast, expected = ruby_answer(kind, text, state)
      [text, state, ast, expected]
    end

    request = JSON.generate({ "cases" => prepared.map { |_, state, ast, _| { "ast" => ast, "instance" => state } } })
    stdout, stderr, status = Open3.capture3(self.class.harness_binary, stdin_data: request)
    expect(status).to be_success, "expr_harness exited #{status.exitstatus}:\n#{stderr}"
    actual = JSON.parse(stdout).fetch("results")

    mismatches = prepared.zip(actual).filter_map do |(text, state, _ast, expected), got|
      next if comparable(got).eql?(comparable(expected))

      "#{text.inspect} over #{state.inspect}\n    ruby: #{expected.inspect}\n    rust: #{got.inspect}"
    end
    expect(mismatches).to be_empty, "#{mismatches.size} of #{EXPR_PARITY_CASES.size} disagree:\n#{mismatches.join("\n")}"
  end

  it "keeps the op roster and the Rust parser in step, so no emitted node is unparseable" do
    ops = Hecks::Bluebook::Expression::AstJson::OPS
    covered = EXPR_PARITY_CASES.flat_map { |kind, text, state| ruby_answer(kind, text, state).first }
    seen = []
    covered.each do |ast|
      Hecks::Bluebook::Expression::AstJson.each_node(ast) do |node|
        seen << node["op"] if node.is_a?(Hash) && node["op"]
      end
    end
    expect(ops - seen.uniq).to be_empty, "ops with no differential case: #{(ops - seen.uniq).inspect}"
  end
end
