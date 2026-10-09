require "hecks"
require "tmpdir"

RSpec.describe "the expression sublanguage" do
  def evaluate(expression, state = {}, args = {})
    Hecks::Bluebook::Expression::Evaluator.call(expression, state, args)
  end

  def two_legs
    [{ "load" => "SESTO", "unload" => "USNYC" }, { "load" => "USNYC", "unload" => "AUSYD" }]
  end

  def one_leg
    [{ "load" => "SESTO", "unload" => "USNYC" }]
  end

  describe "literals" do
    it "reads integers, quoted strings, and booleans", :aggregate_failures do
      expect(evaluate("1 < 2")).to be(true)
      expect(evaluate('"a" == "a"')).to be(true)
      expect(evaluate("true")).to be(true)
      expect(evaluate("false")).to be(false)
    end
  end

  describe "addition" do
    it "adds numeric attributes before comparing them", :aggregate_failures do
      expect(evaluate("amount + adjustment >= 0", { amount: 10 }, { adjustment: -10 })).to be(true)
      expect(evaluate("amount + adjustment >= 0", { amount: 10 }, { adjustment: -11 })).to be(false)
    end
  end

  describe "modulo and scalar coercion" do
    it "evaluates modulo with integers and floats", :aggregate_failures do
      expect(evaluate("cents.modulo(100) == 75", cents: 275)).to be(true)
      expect(evaluate("amount.modulo(divisor) == 1", { amount: 7 }, { divisor: 2.0 })).to be(true)
    end

    it "rejects a zero or non-numeric modulo divisor", :aggregate_failures do
      expect { evaluate("amount.modulo(0)", amount: 7) }.to raise_error(/divided by 0/)
      expect { evaluate('amount.modulo("x")', amount: 7) }.to raise_error(/modulo expects a number/)
    end

    # Modulo zero-checks the untruncated divisor: a divisor like 0.3 must not reach a
    # raw ZeroDivisionError. Uses `resolve` because `evaluate` folds numbers to booleans.
    def resolve(expression, state = {}, args = {})
      Hecks::Bluebook::Expression::Resolver.resolve(expression, state, args)
    end

    it "does not truncate a float divisor into a false zero-division" do
      expect(resolve("amount.modulo(0.3)", amount: 7)).to be_within(1e-9).of(7 % 0.3)
    end

    it "does not truncate float operands, matching Ruby's own modulo", :aggregate_failures do
      expect(resolve("amount.modulo(2.5)", amount: 7.5)).to eq(7.5 % 2.5)
      # the answer modulo would give if it truncated both operands first
      expect(resolve("amount.modulo(2.5)", amount: 7.5)).not_to eq(1)
    end

    it "supports empty maps and scalar string conversion", :aggregate_failures do
      expect(evaluate("metadata.empty?", metadata: {})).to be(true)
      expect(evaluate('ratio.to_s == "1.5"', ratio: 1.5)).to be(true)
    end

    # Pins the outer `.modulo(` split: matching the rightmost occurrence would take the
    # inner call and misparse a nested divisor.
    it "parses a NESTED modulo divisor correctly, not by finding the rightmost .modulo(", :aggregate_failures do
      expect(resolve("0.modulo(amount.modulo(3))", amount: 7)).to eq(0.modulo(7.modulo(3)))
      # 5 % 3 = 2; 7 % 2 = 1
      expect(evaluate("1 == 7.modulo(amount.modulo(3))", amount: 5)).to be(true)
    end

    # Chained calls: the first `.modulo(`'s close paren lands mid-string, so that
    # occurrence must be rejected and the next one tried.
    it "parses a CHAINED modulo receiver correctly too" do
      expect(resolve("amount.modulo(5).modulo(3)", amount: 11)).to eq(11.modulo(5).modulo(3))
    end
  end

  describe "attribute and argument binding" do
    it "reads the subject's own state" do
      expect(evaluate("status == \"available\"", { status: "available" })).to be(true)
    end

    it "lets a command argument shadow the stored value" do
      state = { status: "sold" }
      args  = { status: "available" }
      expect(evaluate("status == \"available\"", state, args)).to be(true)
    end

    it "steps into a value object by dotted path", :aggregate_failures do
      state = { price: { cents: 1200, currency: "USD" } }
      expect(evaluate("price.cents > 1000", state)).to be(true)
      expect(evaluate('price.currency == "USD"', state)).to be(true)
    end
  end

  describe "size" do
    it "counts a list, and folds .length onto .size", :aggregate_failures do
      state = { toppings: [{ name: "Basil" }, { name: "Olive" }] }
      expect(evaluate("toppings.size < 10", state)).to be(true)
      expect(evaluate("toppings.length < 10", state)).to be(true)
      expect(evaluate("toppings.size == 2", state)).to be(true)
    end
  end

  describe "the sign predicates" do
    it "answers positive, negative, and zero", :aggregate_failures do
      answers = [["positive?", 3, true], ["positive?", 0, false], ["positive?", -1, false],
                 ["negative?", -1, true], ["zero?", 0, true], ["zero?", 3, false]]

      expect(answers.map { |test, amount, _| evaluate("amount.#{test}", { amount: amount }) })
        .to eq(answers.map(&:last))
    end

    it "composes with size", :aggregate_failures do
      expect(evaluate("toppings.size.positive?", { toppings: [1] })).to be(true)
      expect(evaluate("toppings.size.positive?", { toppings: [] })).to be(false)
    end

    it "raises rather than answering for a name it cannot resolve" do
      %w[positive? negative? zero?].each do |test|
        expect { evaluate("missing.#{test}") }
          .to raise_error(Hecks::Bluebook::Expression::EvaluationError, /cannot resolve "missing"/)
      end
    end
  end

  describe "emptiness" do
    it "answers for a string, a list, and a map", :aggregate_failures do
      expect(evaluate("label.empty?", { label: "" })).to be true
      expect(evaluate("label.empty?", { label: "Hello" })).to be false
      expect(evaluate("toppings.empty?", { toppings: [] })).to be true
      expect(evaluate("toppings.empty?", { toppings: ["Basil"] })).to be false
    end

    it "reads a string attribute rather than folding through size" do
      expect(evaluate("label.empty?", {}, { label: "Hello" })).to be false
    end

    it "raises when the receiver has no emptiness" do
      expect { evaluate("count.empty?", { count: 3 }) }
        .to raise_error(/empty\? expects a list or string, got 3/)
    end
  end

  describe "negation" do
    it "inverts a verdict", :aggregate_failures do
      expect(evaluate("!ready", { ready: false })).to be true
      expect(evaluate("!ready", { ready: true })).to be false
    end

    it "negates Ruby's truthiness, not a convenient approximation of it", :aggregate_failures do
      expect(evaluate("!count", { count: 0 })).to be false
      expect(evaluate("!label", { label: "" })).to be false
      expect(evaluate("!missing", { missing: nil })).to be true
    end

    it "disagrees with the predicate it negates", :aggregate_failures do
      state = { label: "Hello" }

      expect(evaluate("label.empty?",  state)).to be false
      expect(evaluate("!label.empty?", state)).to be true
    end

    it "binds tighter than the binary operators", :aggregate_failures do
      expect(evaluate("!ready && open", { ready: false, open: true })).to be true
      expect(evaluate("!ready && open", { ready: true,  open: true })).to be false
      expect(evaluate("!(a && b)",      { a: true, b: false })).to be true
    end

    # `!` negates the whole call chain that follows; it must not leak into the haystack
    # text ("!names"), which `Resolver.parse` cannot resolve.
    it "expresses negated membership", :aggregate_failures do
      state = { names: %w[Basil Olive] }

      expect(evaluate('!names.include?("Anchovy")', state)).to be true
      expect(evaluate('!names.include?("Basil")',   state)).to be false
    end

    it "expresses negated membership parenthesized too", :aggregate_failures do
      state = { names: %w[Basil Olive] }

      expect(evaluate('!(names.include?("Anchovy"))', state)).to be true
      expect(evaluate('!(names.include?("Basil"))',   state)).to be false
    end
  end

  describe "to_s" do
    it "renders the scalars a predicate can hold, as Ruby renders them", :aggregate_failures do
      expect(evaluate('count.to_s == "3"',    { count: 3 })).to be true
      expect(evaluate('flag.to_s == "true"',  { flag: true })).to be true
      expect(evaluate('missing.to_s == ""',   { missing: nil })).to be true
    end

    it "composes with emptiness and negation, the shape the chapters use", :aggregate_failures do
      expect(evaluate("!target.to_s.empty?", { target: "ruby" })).to be true
      expect(evaluate("!target.to_s.empty?", { target: nil })).to be false
    end

    it "raises rather than printing a collection" do
      expect { evaluate("toppings.to_s", { toppings: ["Basil"] }) }
        .to raise_error(/to_s expects a scalar/)
    end
  end

  describe "precedence" do
    it "binds || looser than &&", :aggregate_failures do
      expect(evaluate("true || false && false")).to be(true)
      expect(evaluate("(true || false) && false")).to be(false)
    end

    it "keeps parens that do not wrap the whole expression", :aggregate_failures do
      expect(evaluate("(1 < 2) && (3 < 4)")).to be(true)
      expect(evaluate("(1 < 2) && (4 < 3)")).to be(false)
    end

    it "does not mistake >= for >", :aggregate_failures do
      expect(evaluate("2 >= 2")).to be(true)
      expect(evaluate("2 > 2")).to be(false)
      expect(evaluate("2 <= 2")).to be(true)
      expect(evaluate("2 < 2")).to be(false)
      expect(evaluate("2 != 3")).to be(true)
    end
  end

  describe "include?" do
    it "tests membership of a list", :aggregate_failures do
      state = { names: %w[Basil Olive] }
      expect(evaluate('names.include?("Basil")', state)).to be(true)
      expect(evaluate('names.include?("Anchovy")', state)).to be(false)
    end

    # Occurrences are tried left to right, keeping the first whose balanced paren
    # reaches the string's end, so a needle containing `.include?` is not split.
    it "tests membership when the needle ITSELF contains another .include? call" do
      state = { names: %w[Basil Olive], letters: %w[a b] }
      needle = state[:letters].any? { |_l| state[:letters].include?("a") }.to_s
      expect(evaluate('names.include?(letters.any? { |l| letters.include?("a") }.to_s)', state))
        .to eq(state[:names].include?(needle))
    end
  end

  describe "split" do
    it "splits a string on a literal separator, the storehouse-kernel Phrase shape", :aggregate_failures do
      valid   = "dispatch::lexicon::query::command_bus"
      invalid = "dispatch::lexicon"

      expect(evaluate('value.split("::").length == 4', value: valid)).to be(true)
      expect(evaluate('value.split("::").length == 4', value: invalid)).to be(false)
    end

    it "raises when the receiver is not a string" do
      expect { evaluate('value.split("::")', value: 12) }
        .to raise_error(Hecks::Bluebook::Expression::EvaluationError, /split expects a string, got 12/)
    end
  end

  describe "last" do
    it "reads the final segment of a split, composed the way Phrase checks its own terminal casing", :aggregate_failures do
      matching = "dispatch::lexicon::query::command_bus"
      not_matching = "dispatch::lexicon::query::other"

      expect(evaluate('value.split("::").last == "command_bus"', value: matching)).to be(true)
      expect(evaluate('value.split("::").last == "command_bus"', value: not_matching)).to be(false)
    end

    it "raises when the receiver has no #last" do
      expect { evaluate("value.last", value: 12) }
        .to raise_error(Hecks::Bluebook::Expression::EvaluationError, /last expects a list, got 12/)
    end
  end

  describe "first" do
    it "reads the leading segment of a split, the mirror image of .last", :aggregate_failures do
      matching = "dispatch::lexicon::query::command_bus"
      not_matching = "other::lexicon::query::command_bus"

      expect(evaluate('value.split("::").first == "dispatch"', value: matching)).to be(true)
      expect(evaluate('value.split("::").first == "dispatch"', value: not_matching)).to be(false)
    end

    it "raises when the receiver has no #first" do
      expect { evaluate("value.first", value: 12) }
        .to raise_error(Hecks::Bluebook::Expression::EvaluationError, /first expects a list, got 12/)
    end
  end

  describe "block-taking all?/any?/none?" do
    it "aggregates a per-element predicate over a split array", :aggregate_failures do
      four_real_segments = "dispatch::lexicon::query::command_bus"
      one_empty_segment  = "dispatch::::query::command_bus"

      expect(evaluate('value.split("::").all? { |s| s.length > 0 }', value: four_real_segments)).to be(true)
      expect(evaluate('value.split("::").all? { |s| s.length > 0 }', value: one_empty_segment)).to be(false)
    end

    it "does not let the block predicate's own comparison operator split the whole " \
       "expression, the storehouse-kernel Phrase invariant", :aggregate_failures do
      expression = 'value.split("::").length == 4 && value.split("::").all? { |s| s.length > 0 }'

      expect(evaluate(expression, value: "dispatch::lexicon::query::command_bus")).to be(true)
      expect(evaluate(expression, value: "dispatch::lexicon::query")).to be(false)
      expect(evaluate(expression, value: "dispatch::::query::command_bus")).to be(false)
    end

    it "raises when the receiver is not a list" do
      expect { evaluate("value.all? { |s| s.length > 0 }", value: "oops") }
        .to raise_error(Hecks::Bluebook::Expression::EvaluationError, /all\? expects a list, got "oops"/)
    end

    # `[`/`]` must count as grouping in `top_level_index` and `split_addition`, or an
    # operator inside an array literal splits the enclosing expression.
    it "does not let a + inside an array-literal receiver's own element split the enclosing expression", :aggregate_failures do
      expect(evaluate("[0, 1 + 1].all? { |n| n >= 0 }")).to be(true)
      expect(evaluate("[0, 1 + 1].any? { |n| n > 5 }")).to be(false)
    end

    it "handles a block predicate nested inside another block predicate's own predicate, the shipping-domain " \
       "re-routing check this grammar gap forced a workaround for", :aggregate_failures do
      expression = 'legs.any? { |l| l.load == "SESTO" && legs.any? { |o| o.load == "USNYC" } }'

      expect(evaluate(expression, legs: two_legs)).to be(true)
      expect(evaluate(expression, legs: one_leg)).to be(false)
    end
  end

  describe "find" do
    let(:legs) do
      [
        { "load" => "SESTO", "unload" => "USNYC", "voyage" => "V001" },
        { "load" => "USNYC", "unload" => "AUSYD", "voyage" => "V002" }
      ]
    end

    it "projects a field off the first matching element, the find-then-project shape a caller-precomputed field " \
       "used to stand in for" do
      expect(evaluate('legs.find { |l| l.load == "USNYC" }.voyage == "V002"', legs: legs)).to be(true)
    end

    it "resolves to nil, not an error, when no element matches — a normal 'no leg after this one' outcome", :aggregate_failures do
      expect(evaluate('legs.find { |l| l.load == "ZZZZZ" }.voyage == "V002"', legs: legs)).to be(false)
      # bare (no comparison): the leaf is truthy-cast, so nil reads as false
      expect(evaluate('legs.find { |l| l.load == "ZZZZZ" }.voyage', legs: legs)).to be(false)
    end

    it "composes bare, with no trailing path, the same way .last does", :aggregate_failures do
      expect(evaluate('legs.find { |l| l.load == "USNYC" }.present?', legs: legs)).to be(true)
      expect(evaluate('legs.find { |l| l.load == "ZZZZZ" }.present?', legs: legs)).to be(false)
    end

    it "raises when the receiver is not a list" do
      expect { evaluate('value.find { |l| l.load == "USNYC" }.voyage', value: "oops") }
        .to raise_error(Hecks::Bluebook::Expression::EvaluationError, /find expects a list, got "oops"/)
    end

    it "nests inside a block predicate's own predicate — the shipping-domain re-routing check that first exposed " \
       "this: scanning for .find and .any?/.all?/.none? SEPARATELY found the wrong (inner) occurrence when they " \
       "nest, the same crash signature nested .any? had before parse_block_opener unified the scan",
       :aggregate_failures do
      expression = 'legs.any? { |leg| leg.load == "SESTO" && legs.find { |o| o.load == leg.unload }.load == "USNYC" }'

      expect(evaluate(expression, legs: two_legs)).to be(true)
      expect(evaluate(expression, legs: one_leg)).to be(false)
    end

    it "nests the OTHER direction too — a block predicate inside .find's own predicate" do
      expression = 'legs.find { |leg| legs.any? { |o| o.load == leg.unload } }.load == "SESTO"'

      expect(evaluate(expression, legs: two_legs)).to be(true)
    end
  end

  describe "start_with? and end_with?" do
    it "checks both ends of a string, the storehouse-kernel Params JSON-object shape", :aggregate_failures do
      expression = 'value.start_with?("{") && value.end_with?("}")'

      expect(evaluate(expression, value: '{"a":1}')).to be(true)
      expect(evaluate(expression, value: "[1,2]")).to be(false)
    end

    it "raises when the receiver is not a string", :aggregate_failures do
      expect { evaluate('value.start_with?("{")', value: 12) }
        .to raise_error(Hecks::Bluebook::Expression::EvaluationError, /start_with\? expects a string, got 12/)
      expect { evaluate('value.end_with?("}")', value: 12) }
        .to raise_error(Hecks::Bluebook::Expression::EvaluationError, /end_with\? expects a string, got 12/)
    end
  end

  describe "strip, lstrip and rstrip" do
    it "trim Ruby's whitespace set from the ends they name", :aggregate_failures do
      padded = "\0 \t\n a b \v\f\r\0"

      expect(evaluate('!value.to_s.strip.empty?', value: "  \f ")).to be(false)
      expect(evaluate('value.strip == "a b"', value: padded)).to be(true)
      expect(evaluate('value.lstrip.start_with?("a")', value: padded)).to be(true)
      expect(evaluate('value.lstrip.end_with?("a")', value: padded)).to be(false)
      expect(evaluate('value.rstrip.end_with?("b")', value: padded)).to be(true)
      expect(evaluate('value.rstrip.start_with?("a")', value: padded)).to be(false)
    end

    it "leave a Unicode space alone, as String#strip does" do
      expect(evaluate("value.strip.size == 3", value: "\u00a0a\u00a0")).to be(true)
    end

    it "raise when the receiver is not a string", :aggregate_failures do
      expect { evaluate("value.strip.empty?", value: nil) }
        .to raise_error(Hecks::Bluebook::Expression::EvaluationError, /strip expects a string, got nil/)
      expect { evaluate("value.rstrip.empty?", value: 12) }
        .to raise_error(Hecks::Bluebook::Expression::EvaluationError, /strip expects a string, got 12/)
    end
  end

  describe "single-field VO scalar unwrap" do
    SingleFieldDouble = Struct.new(:value) do
      def to_h = { value: value }
    end

    it "unwraps a bare (undotted) lookup of a single-field VO to its raw scalar", :aggregate_failures do
      wrapped = SingleFieldDouble.new("active")

      expect(evaluate('status == "active"', status: wrapped)).to be(true)
      expect(evaluate('status == "inactive"', status: wrapped)).to be(false)
    end

    it "leaves a dotted lookup reaching a VO's own #[]-addressed field untouched (already raw)" do
      wrapped = SingleFieldDouble.new("active")

      expect(evaluate('status.value == "active"', status: wrapped)).to be(true)
    end

    it "unwraps the terminal value of a dotted lookup that navigates to a nested single-field VO", :aggregate_failures do
      # The final hop lands on a VO and must unwrap like a bare lookup, or `==` is
      # always false (Value#== only equals another Value).
      leg = { voyage: SingleFieldDouble.new("SF-NY") }

      expect(evaluate('leg.voyage == "SF-NY"', leg: leg)).to be(true)
      expect(evaluate('leg.voyage == "SF-LA"', leg: leg)).to be(false)
    end

    it "unwraps both sides when comparing two nested single-field VOs directly" do
      leg = { voyage: SingleFieldDouble.new("SF-NY") }
      other_voyage = SingleFieldDouble.new("SF-NY")

      expect(evaluate("leg.voyage == other_voyage", leg: leg, other_voyage: other_voyage)).to be(true)
    end
  end

  describe "match?/present?/blank?" do
    it "matches a receiver against a regex literal, the storehouse-kernel format-validation shape", :aggregate_failures do
      expect(evaluate('value.match?(/\A\d{5}\z/)', value: "94103")).to be(true)
      expect(evaluate('value.match?(/\A\d{5}\z/)', value: "not-a-zip")).to be(false)
    end

    it "treats present?/blank? by Rails-standard emptiness, not bare nil?", :aggregate_failures do
      expect(evaluate("value.present?", value: "x")).to be(true)
      expect(evaluate("value.present?", value: "")).to be(false)
      expect(evaluate("value.blank?", value: "")).to be(true)
      expect(evaluate("value.blank?", value: nil)).to be(true)
    end
  end

  describe "present?/blank? on lists" do
    it "answers a non-empty list is present, pairs or not, without raising", :aggregate_failures do
      expect(evaluate("value.present?", value: [0])).to be(true)
      expect(evaluate("value.blank?", value: [0])).to be(false)
      expect(evaluate("value.present?", value: [[1, 2]])).to be(true)
      expect(evaluate("value.blank?", value: [])).to be(true)
    end
  end

  describe "set?/unset? -- deliberately narrower than present?/blank?" do
    it "asks only whether the receiver is nil, never whether it is empty", :aggregate_failures do
      expect(evaluate("value.set?", value: nil)).to be(false)
      expect(evaluate("value.unset?", value: nil)).to be(true)

      # An assigned-but-empty value is set, unlike `"".present?`.
      expect(evaluate("value.set?", value: "")).to be(true)
      expect(evaluate("value.unset?", value: "")).to be(false)
      expect(evaluate("value.set?", value: [])).to be(true)
    end

    it "reads an optional field's nil the same way whether it was never assigned or explicitly cleared", :aggregate_failures do
      expect(evaluate("superseded_by.unset?", superseded_by: nil)).to be(true)
      expect(evaluate("superseded_by.set?", superseded_by: nil)).to be(false)
      expect(evaluate("superseded_by.unset?", superseded_by: "evt-1")).to be(false)
    end
  end

  describe "comparison_detail" do
    def detail(expression, state = {}, args = {})
      Hecks::Bluebook::Expression::Evaluator.comparison_detail(expression, state, args)
    end

    it "reports the resolved operands of a bare comparison", :aggregate_failures do
      expect(detail("status == \"open\"", status: "closed")).to eq('left: "closed", right: "open"')
      expect(detail("balance.cents >= 0", balance: { cents: -5 })).to eq("left: -5, right: 0")
    end

    it "renders a nil operand the same way every other refusal does" do
      expect(detail("superseded_by == nil", superseded_by: nil)).to eq("left: nil, right: nil")
    end

    it "is nil for shapes with no single honest left/right — Or/And/Not/Include/Resolve", :aggregate_failures do
      expect(detail("a == 1 || b == 2", a: 0, b: 0)).to be_nil
      expect(detail("a == 1 && b == 2", a: 0, b: 0)).to be_nil
      expect(detail("!(a == 1)", a: 1)).to be_nil
      expect(detail("names.include?(\"x\")", names: [])).to be_nil
      expect(detail("flag", flag: false)).to be_nil
    end

    it "is nil, not raised, when an operand itself fails to resolve" do
      expect(detail("totally_unknown == 1")).to be_nil
    end
  end

  describe "agreeing with Ruby itself" do
    def agrees?(expression, bindings)
      mine = begin
        evaluate(expression, bindings)
      rescue Hecks::Bluebook::Expression::EvaluationError
        :raised
      end
      theirs = rubys_answer(expression, bindings)

      mine == theirs || (mine != :raised && theirs != :raised && mine == !!theirs)
    end

    def rubys_answer(expression, bindings)
      locals = bindings.map { |name, value| "#{name} = #{value.inspect}; " }.join
      eval("#{locals}#{expression}", binding, __FILE__, __LINE__) # e.g. amount.modulo(3)
    rescue StandardError
      :raised
    end

    it "treats 0 and empty string as TRUE, exactly as Ruby does", :aggregate_failures do
      expect(agrees?("count", count: 0)).to be(true)
      expect(agrees?("label", label: "")).to be(true)
      expect(evaluate("count", count: 0)).to be(true)
      expect(evaluate("label", label: "")).to be(true)
    end

    it "treats nil and false as the only falsy values, exactly as Ruby does", :aggregate_failures do
      expect(evaluate("flag", flag: false)).to be(false)
      expect(evaluate("flag", flag: nil)).to be(false)
    end

    it "does not equate a number with its string, exactly as Ruby does", :aggregate_failures do
      expect(agrees?('count == "1"', count: 1)).to be(true)
      expect(evaluate('count == "1"', count: 1)).to be(false)
      expect(evaluate("count == 1", count: 1)).to be(true)
      expect(evaluate("count == 1.0", count: 1)).to be(true)
    end

    it "does not equate a list member with its string, exactly as Ruby does", :aggregate_failures do
      expect(agrees?("sizes.include?(10)", sizes: ["10"])).to be(true)
      expect(evaluate("sizes.include?(10)", sizes: ["10"])).to be(false)
      expect(agrees?('sizes.include?("10")', sizes: [10])).to be(true)
      expect(evaluate('sizes.include?("10")', sizes: [10])).to be(false)
    end

    it "equates a list member across numeric kinds, exactly as Ruby does", :aggregate_failures do
      expect(agrees?("scores.include?(1.0)", scores: [1])).to be(true)
      expect(evaluate("scores.include?(1.0)", scores: [1])).to be(true)
      expect(evaluate("scores.include?(1)", scores: [1.0])).to be(true)
    end

    it "refuses a non-string needle in a string, exactly as Ruby does", :aggregate_failures do
      expect(agrees?("code.include?(5)", code: "a5b")).to be(true)
      expect { evaluate("code.include?(5)", code: "a5b") }
        .to raise_error(Hecks::Bluebook::Expression::EvaluationError,
                        /no implicit conversion of Integer into String/)
    end

    it "still reads a substring when the needle is a string", :aggregate_failures do
      expect(agrees?('address.include?("@")', address: "ada@example.com")).to be(true)
      expect(evaluate('address.include?("@")', address: "ada@example.com")).to be(true)
    end

    it "refuses an incomparable ordering, exactly as Ruby does", :aggregate_failures do
      expect(agrees?("label < 3", label: "abc")).to be(true)
      expect { evaluate("label < 3", label: "abc") }
        .to raise_error(Hecks::Bluebook::Expression::EvaluationError, /comparison of String with 3 failed/)
    end

    it "orders strings against strings", :aggregate_failures do
      expect(evaluate('label < "b"', label: "a")).to be(true)
      expect(evaluate('label < "b"', label: "c")).to be(false)
    end
  end

  describe "refusing what it cannot evaluate" do
    it "raises on a name it cannot resolve" do
      expect { evaluate("mispelled_attribute > 0") }
        .to raise_error(Hecks::Bluebook::Expression::EvaluationError, /cannot resolve "mispelled_attribute"/)
    end

    it "raises when a sign predicate has no number" do
      expect { evaluate("label.positive?", { label: "abc" }) }
        .to raise_error(Hecks::Bluebook::Expression::EvaluationError, /positive\? expects a number/)
    end

    it "raises when size has nothing to count" do
      expect { evaluate("count.size", { count: 3 }) }
        .to raise_error(Hecks::Bluebook::Expression::EvaluationError, /size expects a list or string/)
    end

    it "still resolves a declared attribute that happens to be nil" do
      expect(evaluate("customer_name == nil", { customer_name: nil })).to be(true)
    end

    # Must refuse with `EvaluationError`, not leak Array#[]'s raw TypeError.
    it "refuses, rather than raising a raw TypeError, a dotted lookup onto a list" do
      expect { evaluate("list.foo", { list: [1, 2, 3] }) }
        .to raise_error(Hecks::Bluebook::Expression::EvaluationError, /cannot read "foo"/)
    end

    # Must refuse with `EvaluationError`, not leak Regexp.new's raw RegexpError.
    it "refuses, rather than raising a raw RegexpError, an invalid match? pattern" do
      expect { evaluate("value.match?(/[/)", value: "x") }
        .to raise_error(Hecks::Bluebook::Expression::EvaluationError, /invalid pattern/)
    end
  end

  describe "extraction" do
    it "lowers a real Ruby block to canonical text" do
      canonical = Hecks::Adapters::Prism.canonical(proc { 1 < 2 })
      expect(canonical).to eq("1 < 2")
    end

    it "folds .length onto .size while extracting" do
      canonical = Hecks::Adapters::Prism.canonical(proc { [].length < 10 })
      expect(canonical).to include(".size")
    end
  end

  # `Prism::TREES` caches parsed ASTs per path for the process; `forget`/`forget_all`
  # invalidate it for code that reloads an edited file.
  describe "cache invalidation" do
    around do |example|
      Dir.mktmpdir do |dir|
        @tmp_file = File.join(dir, "sample.rb")
        File.write(@tmp_file, "1")
        example.run
      end
    end

    let(:prism) { Hecks::Adapters::Prism }

    it "forget re-parses a specific file's tree on the next read, not before", :aggregate_failures do
      first = prism.tree_for(@tmp_file)
      File.write(@tmp_file, "2")
      expect(prism.tree_for(@tmp_file)).to equal(first), "still cached — a rewrite alone must not invalidate it"
      prism.forget(@tmp_file)
      expect(prism.tree_for(@tmp_file)).not_to equal(first)
    end

    it "forget_all clears every cached tree, not just one path" do
      first = prism.tree_for(@tmp_file)
      prism.forget_all
      File.write(@tmp_file, "2")
      expect(prism.tree_for(@tmp_file)).not_to equal(first)
    end

    it "finds the first block starting on a line, and none on a line without one", :aggregate_failures do
      File.write(@tmp_file, "a { 1 }\nb do\n  c { 2 }\nend\nd { 3 }; e { 4 }\n")
      slices = [1, 3, 5].map { |line| prism.block_node_at(@tmp_file, line).body.slice }

      expect(slices).to eq(["1", "2", "3"])
      expect(prism.block_node_at(@tmp_file, 2).location.start_line).to eq(2)
      expect(prism.block_node_at(@tmp_file, 4)).to be_nil
    end

    it "walks a file's tree once for all its block lookups" do
      File.write(@tmp_file, "a { 1 }\nb { 2 }\n")
      allow(prism).to receive(:blocks_by_line).and_call_original
      prism.block_node_at(@tmp_file, 1)
      prism.block_node_at(@tmp_file, 2)
      expect(prism).to have_received(:blocks_by_line).once
    end

    it "indexes a file's blocks afresh after forget" do
      File.write(@tmp_file, "a { 1 }\nb { 2 }\n")
      prism.block_node_at(@tmp_file, 1)
      File.write(@tmp_file, "a { 1 }\n\nb { 22 }\n")
      prism.forget(@tmp_file)
      expect([3, 2].map { |line| prism.block_node_at(@tmp_file, line)&.body&.slice }).to eq(["22", nil])
    end

    it "forget on a path never cached is a no-op, not a raise" do
      expect { Hecks::Adapters::Prism.forget("/no/such/file.rb") }.not_to raise_error
    end
  end

  describe "caching" do
    let(:evaluator) { Hecks::Bluebook::Expression::Evaluator }

    def warm(expr, amount: 1, reset: true)
      evaluator.ast_cache.delete(expr) if reset
      evaluate(expr, amount: amount)
      evaluator.ast_cache.fetch(expr)
    end

    it "parses a leaf expression's grammar once, no matter how many times its predicate runs" do
      left_leaf = warm("amount > 0").left
      [-1, 0].each { |amount| warm("amount > 0", amount: amount, reset: false) }

      expect(evaluator.ast_cache.fetch("amount > 0").left).to equal(left_leaf)
    end

    it "parses a leaf's nested sub-expressions once too — the receiver of a sign test, not just the top", :aggregate_failures do
      sign_test = warm("amount.positive?").expr
      resolved_again = warm("amount.positive?", amount: -1, reset: false).expr

      expect(resolved_again).to equal(sign_test)
      expect(resolved_again.receiver).to equal(sign_test.receiver)
    end
  end

  # `parse` never yields an unknown node, so the `else` refusal in `interpret` is
  # reachable only with a hand-built AST; this calls it directly.
  describe "interpret's own exhaustiveness backstop" do
    UnknownNode = Struct.new(:whatever)

    it "Evaluator.interpret refuses a node type it has no case for, rather than silently returning nil" do
      expect do
        Hecks::Bluebook::Expression::Evaluator.interpret(UnknownNode.new, {}, {})
      end.to raise_error(Hecks::Bluebook::Expression::EvaluationError, /no interpreter handles/)
    end

    it "Resolver.interpret refuses a node type it has no case for, rather than silently returning nil" do
      expect do
        Hecks::Bluebook::Expression::Resolver.interpret(UnknownNode.new, {}, {})
      end.to raise_error(Hecks::Bluebook::Expression::EvaluationError, /no interpreter handles/)
    end
  end

  # A `+` inside a block body must not split the enclosing expression, so the bare
  # spelling must answer like its parenthesized twin.
  describe "arithmetic inside a block predicate" do
    let(:attrs) do
      { kings:  [{ status: "on_board", square: { file: 6, rank: 0 } }],
        to:     { file: 5, rank: 0 },
        square: { file: 7, rank: 0 } }
    end

    it "parses a bare `+` inside the block body as the block's own arithmetic, not the expression's", :aggregate_failures do
      expect(evaluate("kings.any? { |k| k.square.file == to.file + 1 && square.file > k.square.file }", {}, attrs))
        .to be(true)
      expect(evaluate("kings.any? { |k| k.square.file == to.file + 1 && square.file > k.square.file }",
                      {}, attrs.merge(square: { file: 2, rank: 0 }))).to be(false)
    end

    it "answers exactly as the parenthesized spelling always has" do
      bare   = "kings.any? { |k| k.square.file == to.file + 1 && square.file > k.square.file }"
      parens = "kings.any? { |k| (k.square.file == to.file + 1) && (square.file > k.square.file) }"
      expect(evaluate(bare, {}, attrs)).to eq(evaluate(parens, {}, attrs))
    end

    it "still splits a genuinely top-level addition that merely CONTAINS a block predicate" do
      expect(evaluate("pending + extras.size == 3", { pending: 2 }, { extras: [1] })).to be(true)
    end
  end

  # A stored `false` must not fall through to the other key spelling and read as nil.
  describe "dotted lookup onto a stored false" do
    it "reads a false-valued nested member as itself, not as absent", :aggregate_failures do
      expect(evaluate("flags.active == false", { flags: { active: false } })).to be(true)
      expect(evaluate("flags.active == true",  { flags: { active: false } })).to be(false)
    end

    it "still reads a true-valued nested member" do
      expect(evaluate("flags.active == true", { flags: { active: true } })).to be(true)
    end
  end
end
