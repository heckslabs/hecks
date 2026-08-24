require "hecks"

RSpec.describe "the expression sublanguage" do
  def evaluate(expression, state = {}, args = {})
    Hecks::Bluebook::Expression::Evaluator.call(expression, state, args)
  end

  describe "literals" do
    it "reads integers, quoted strings, and booleans" do
      expect(evaluate("1 < 2")).to be(true)
      expect(evaluate('"a" == "a"')).to be(true)
      expect(evaluate("true")).to be(true)
      expect(evaluate("false")).to be(false)
    end
  end

  describe "addition" do
    it "adds numeric attributes before comparing them" do
      expect(evaluate("amount + adjustment >= 0", { amount: 10 }, { adjustment: -10 })).to be(true)
      expect(evaluate("amount + adjustment >= 0", { amount: 10 }, { adjustment: -11 })).to be(false)
    end
  end

  describe "modulo and scalar coercion" do
    it "evaluates modulo with integers and floats" do
      expect(evaluate("cents.modulo(100) == 75", cents: 275)).to be(true)
      expect(evaluate("amount.modulo(divisor) == 1", { amount: 7 }, { divisor: 2.0 })).to be(true)
    end

    it "rejects a zero or non-numeric modulo divisor" do
      expect { evaluate("amount.modulo(0)", amount: 7) }.to raise_error(/divided by 0/)
      expect { evaluate('amount.modulo("x")', amount: 7) }.to raise_error(/modulo expects a number/)
    end

    it "supports empty maps and scalar string conversion" do
      expect(evaluate("metadata.empty?", metadata: {})).to be(true)
      expect(evaluate('ratio.to_s == "1.5"', ratio: 1.5)).to be(true)
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

    it "steps into a value object by dotted path" do
      state = { price: { cents: 1200, currency: "USD" } }
      expect(evaluate("price.cents > 1000", state)).to be(true)
      expect(evaluate('price.currency == "USD"', state)).to be(true)
    end
  end

  describe "size" do
    it "counts a list, and folds .length onto .size" do
      state = { toppings: [{ name: "Basil" }, { name: "Olive" }] }
      expect(evaluate("toppings.size < 10", state)).to be(true)
      expect(evaluate("toppings.length < 10", state)).to be(true)
      expect(evaluate("toppings.size == 2", state)).to be(true)
    end
  end

  describe "the sign predicates" do
    it "answers positive, negative, and zero" do
      expect(evaluate("amount.positive?", { amount: 3 })).to be(true)
      expect(evaluate("amount.positive?", { amount: 0 })).to be(false)
      expect(evaluate("amount.positive?", { amount: -1 })).to be(false)

      expect(evaluate("amount.negative?", { amount: -1 })).to be(true)
      expect(evaluate("amount.zero?", { amount: 0 })).to be(true)
      expect(evaluate("amount.zero?", { amount: 3 })).to be(false)
    end

    it "composes with size" do
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
    it "answers for a string, a list, and a map" do
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
    it "inverts a verdict" do
      expect(evaluate("!ready", { ready: false })).to be true
      expect(evaluate("!ready", { ready: true })).to be false
    end

    it "negates Ruby's truthiness, not a convenient approximation of it" do
      expect(evaluate("!count", { count: 0 })).to be false
      expect(evaluate("!label", { label: "" })).to be false
      expect(evaluate("!missing", { missing: nil })).to be true
    end

    it "disagrees with the predicate it negates" do
      state = { label: "Hello" }

      expect(evaluate("label.empty?",  state)).to be false
      expect(evaluate("!label.empty?", state)).to be true
    end

    it "binds tighter than the binary operators" do
      expect(evaluate("!ready && open", { ready: false, open: true })).to be true
      expect(evaluate("!ready && open", { ready: true,  open: true })).to be false
      expect(evaluate("!(a && b)",      { a: true, b: false })).to be true
    end
  end

  describe "to_s" do
    it "renders the scalars a predicate can hold, as Ruby renders them" do
      expect(evaluate('count.to_s == "3"',    { count: 3 })).to be true
      expect(evaluate('flag.to_s == "true"',  { flag: true })).to be true
      expect(evaluate('missing.to_s == ""',   { missing: nil })).to be true
    end

    it "composes with emptiness and negation, the shape the chapters use" do
      expect(evaluate("!target.to_s.empty?", { target: "ruby" })).to be true
      expect(evaluate("!target.to_s.empty?", { target: nil })).to be false
    end

    it "raises rather than printing a collection" do
      expect { evaluate("toppings.to_s", { toppings: ["Basil"] }) }
        .to raise_error(/to_s expects a scalar/)
    end
  end

  describe "precedence" do
    it "binds || looser than &&" do
      expect(evaluate("true || false && false")).to be(true)
      expect(evaluate("(true || false) && false")).to be(false)
    end

    it "keeps parens that do not wrap the whole expression" do
      expect(evaluate("(1 < 2) && (3 < 4)")).to be(true)
      expect(evaluate("(1 < 2) && (4 < 3)")).to be(false)
    end

    it "does not mistake >= for >" do
      expect(evaluate("2 >= 2")).to be(true)
      expect(evaluate("2 > 2")).to be(false)
      expect(evaluate("2 <= 2")).to be(true)
      expect(evaluate("2 < 2")).to be(false)
      expect(evaluate("2 != 3")).to be(true)
    end
  end

  describe "include?" do
    it "tests membership of a list" do
      state = { names: %w[Basil Olive] }
      expect(evaluate('names.include?("Basil")', state)).to be(true)
      expect(evaluate('names.include?("Anchovy")', state)).to be(false)
    end
  end

  describe "split" do
    it "splits a string on a literal separator, the storehouse-kernel Phrase shape" do
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
    it "reads the final segment of a split, composed the way Phrase checks its own terminal casing" do
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
    it "reads the leading segment of a split, the mirror image of .last" do
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
    it "aggregates a per-element predicate over a split array" do
      four_real_segments = "dispatch::lexicon::query::command_bus"
      one_empty_segment  = "dispatch::::query::command_bus"

      expect(evaluate('value.split("::").all? { |s| s.length > 0 }', value: four_real_segments)).to be(true)
      expect(evaluate('value.split("::").all? { |s| s.length > 0 }', value: one_empty_segment)).to be(false)
    end

    it "does not let the block predicate's own comparison operator split the whole expression, the storehouse-kernel Phrase invariant" do
      expression = 'value.split("::").length == 4 && value.split("::").all? { |s| s.length > 0 }'

      expect(evaluate(expression, value: "dispatch::lexicon::query::command_bus")).to be(true)
      expect(evaluate(expression, value: "dispatch::lexicon::query")).to be(false)
      expect(evaluate(expression, value: "dispatch::::query::command_bus")).to be(false)
    end

    it "raises when the receiver is not a list" do
      expect { evaluate("value.all? { |s| s.length > 0 }", value: "oops") }
        .to raise_error(Hecks::Bluebook::Expression::EvaluationError, /all\? expects a list, got "oops"/)
    end

    it "handles a block predicate nested inside another block predicate's own predicate, the shipping-domain re-routing check this grammar gap forced a workaround for" do
      # legs.any? { |l| an outer condition on l, AND some other leg satisfies an inner condition }
      legs_with_a_later_leg = [
        { "load" => "SESTO", "unload" => "USNYC" },
        { "load" => "USNYC", "unload" => "AUSYD" }
      ]
      legs_without_a_later_leg = [
        { "load" => "SESTO", "unload" => "USNYC" }
      ]
      expression = 'legs.any? { |l| l.load == "SESTO" && legs.any? { |o| o.load == "USNYC" } }'

      expect(evaluate(expression, legs: legs_with_a_later_leg)).to be(true)
      expect(evaluate(expression, legs: legs_without_a_later_leg)).to be(false)
    end
  end

  describe "find" do
    let(:legs) do
      [
        { "load" => "SESTO", "unload" => "USNYC", "voyage" => "V001" },
        { "load" => "USNYC", "unload" => "AUSYD", "voyage" => "V002" }
      ]
    end

    it "projects a field off the first matching element, the find-then-project shape a caller-precomputed field used to stand in for" do
      expect(evaluate('legs.find { |l| l.load == "USNYC" }.voyage == "V002"', legs: legs)).to be(true)
    end

    it "resolves to nil, not an error, when no element matches — a normal 'no leg after this one' outcome" do
      expect(evaluate('legs.find { |l| l.load == "ZZZZZ" }.voyage == "V002"', legs: legs)).to be(false)
      # bare (no comparison), Evaluator truthy-casts every leaf's raw value
      # the same way it does for `.last`/`.present?` — nil casts to false,
      # not an error, exactly what "no leg found" should mean here.
      expect(evaluate('legs.find { |l| l.load == "ZZZZZ" }.voyage', legs: legs)).to be(false)
    end

    it "composes bare, with no trailing path, the same way .last does" do
      expect(evaluate('legs.find { |l| l.load == "USNYC" }.present?', legs: legs)).to be(true)
      expect(evaluate('legs.find { |l| l.load == "ZZZZZ" }.present?', legs: legs)).to be(false)
    end

    it "raises when the receiver is not a list" do
      expect { evaluate('value.find { |l| l.load == "USNYC" }.voyage', value: "oops") }
        .to raise_error(Hecks::Bluebook::Expression::EvaluationError, /find expects a list, got "oops"/)
    end

    it "nests inside a block predicate's own predicate — the shipping-domain re-routing check that first exposed this: scanning for .find and .any?/.all?/.none? SEPARATELY found the wrong (inner) occurrence when they nest, the same crash signature nested .any? had before parse_block_opener unified the scan" do
      two_legs = [
        { "load" => "SESTO", "unload" => "USNYC" },
        { "load" => "USNYC", "unload" => "AUSYD" }
      ]
      one_leg = [{ "load" => "SESTO", "unload" => "USNYC" }]
      expression = 'legs.any? { |leg| leg.load == "SESTO" && legs.find { |o| o.load == leg.unload }.load == "USNYC" }'

      expect(evaluate(expression, legs: two_legs)).to be(true)
      expect(evaluate(expression, legs: one_leg)).to be(false)
    end

    it "nests the OTHER direction too — a block predicate inside .find's own predicate" do
      two_legs = [
        { "load" => "SESTO", "unload" => "USNYC" },
        { "load" => "USNYC", "unload" => "AUSYD" }
      ]
      expression = 'legs.find { |leg| legs.any? { |o| o.load == leg.unload } }.load == "SESTO"'

      expect(evaluate(expression, legs: two_legs)).to be(true)
    end
  end

  describe "start_with? and end_with?" do
    it "checks both ends of a string, the storehouse-kernel Params JSON-object shape" do
      expression = 'value.start_with?("{") && value.end_with?("}")'

      expect(evaluate(expression, value: '{"a":1}')).to be(true)
      expect(evaluate(expression, value: "[1,2]")).to be(false)
    end

    it "raises when the receiver is not a string" do
      expect { evaluate('value.start_with?("{")', value: 12) }
        .to raise_error(Hecks::Bluebook::Expression::EvaluationError, /start_with\? expects a string, got 12/)
      expect { evaluate('value.end_with?("}")', value: 12) }
        .to raise_error(Hecks::Bluebook::Expression::EvaluationError, /end_with\? expects a string, got 12/)
    end
  end

  describe "single-field VO scalar unwrap" do
    SingleFieldDouble = Struct.new(:value) do
      def to_h = { value: value }
    end

    it "unwraps a bare (undotted) lookup of a single-field VO to its raw scalar" do
      wrapped = SingleFieldDouble.new("active")

      expect(evaluate('status == "active"', status: wrapped)).to be(true)
      expect(evaluate('status == "inactive"', status: wrapped)).to be(false)
    end

    it "leaves a dotted lookup reaching a VO's own #[]-addressed field untouched (already raw)" do
      wrapped = SingleFieldDouble.new("active")

      expect(evaluate('status.value == "active"', status: wrapped)).to be(true)
    end

    it "unwraps the terminal value of a dotted lookup that navigates to a nested single-field VO" do
      # the leg.voyage shape: `leg` is an entity/hash, `voyage` is itself
      # a single-field VO -- the dotted walk's intermediate hop reaches
      # `leg` via #[], but the FINAL hop lands on a VO and must unwrap
      # it the same as a bare lookup would, or `==` silently returns
      # false for every comparison (Value#== only equals another Value).
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
    it "matches a receiver against a regex literal, the storehouse-kernel format-validation shape" do
      expect(evaluate('value.match?(/\A\d{5}\z/)', value: "94103")).to be(true)
      expect(evaluate('value.match?(/\A\d{5}\z/)', value: "not-a-zip")).to be(false)
    end

    it "treats present?/blank? by Rails-standard emptiness, not bare nil?" do
      expect(evaluate("value.present?", value: "x")).to be(true)
      expect(evaluate("value.present?", value: "")).to be(false)
      expect(evaluate("value.blank?", value: "")).to be(true)
      expect(evaluate("value.blank?", value: nil)).to be(true)
    end
  end

  describe "agreeing with Ruby itself" do
    def agrees?(expression, bindings)
      mine = begin
        evaluate(expression, bindings)
      rescue Hecks::Bluebook::Expression::EvaluationError
        :raised
      end

      theirs = begin
        locals = bindings.map { |name, value| "#{name} = #{value.inspect}; " }.join
        eval("#{locals}#{expression}")
      rescue StandardError
        :raised
      end

      mine == theirs || (mine != :raised && theirs != :raised && mine == !!theirs)
    end

    it "treats 0 and empty string as TRUE, exactly as Ruby does" do
      expect(agrees?("count", count: 0)).to be(true)
      expect(agrees?("label", label: "")).to be(true)
      expect(evaluate("count", count: 0)).to be(true)
      expect(evaluate("label", label: "")).to be(true)
    end

    it "treats nil and false as the only falsy values, exactly as Ruby does" do
      expect(evaluate("flag", flag: false)).to be(false)
      expect(evaluate("flag", flag: nil)).to be(false)
    end

    it "does not equate a number with its string, exactly as Ruby does" do
      expect(agrees?('count == "1"', count: 1)).to be(true)
      expect(evaluate('count == "1"', count: 1)).to be(false)
      expect(evaluate("count == 1", count: 1)).to be(true)
      expect(evaluate("count == 1.0", count: 1)).to be(true)
    end

    it "does not equate a list member with its string, exactly as Ruby does" do
      expect(agrees?("sizes.include?(10)", sizes: ["10"])).to be(true)
      expect(evaluate("sizes.include?(10)", sizes: ["10"])).to be(false)
      expect(agrees?('sizes.include?("10")', sizes: [10])).to be(true)
      expect(evaluate('sizes.include?("10")', sizes: [10])).to be(false)
    end

    it "equates a list member across numeric kinds, exactly as Ruby does" do
      expect(agrees?("scores.include?(1.0)", scores: [1])).to be(true)
      expect(evaluate("scores.include?(1.0)", scores: [1])).to be(true)
      expect(evaluate("scores.include?(1)", scores: [1.0])).to be(true)
    end

    it "refuses a non-string needle in a string, exactly as Ruby does" do
      expect(agrees?("code.include?(5)", code: "a5b")).to be(true)
      expect { evaluate("code.include?(5)", code: "a5b") }
        .to raise_error(Hecks::Bluebook::Expression::EvaluationError,
                        /no implicit conversion of Integer into String/)
    end

    it "still reads a substring when the needle is a string" do
      expect(agrees?('address.include?("@")', address: "ada@example.com")).to be(true)
      expect(evaluate('address.include?("@")', address: "ada@example.com")).to be(true)
    end

    it "refuses an incomparable ordering, exactly as Ruby does" do
      expect(agrees?("label < 3", label: "abc")).to be(true)
      expect { evaluate("label < 3", label: "abc") }
        .to raise_error(Hecks::Bluebook::Expression::EvaluationError, /comparison of String with 3 failed/)
    end

    it "orders strings against strings" do
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

  # `Hecks::Adapters::Prism::TREES` caches a file's parsed AST for
  # the life of the process, keyed by path — correct for every ordinary
  # caller, wrong for anything that reloads an edited file in-process
  # (found for real building `Hecks::Codemod`, see its own file
  # header). `forget`/`forget_all` are the real invalidation API.
  describe "cache invalidation" do
    around do |example|
      Dir.mktmpdir { |dir| @tmp_file = File.join(dir, "sample.rb"); example.run }
    end

    it "forget re-parses a specific file's tree on the next read, not before" do
      File.write(@tmp_file, "1")
      first = Hecks::Adapters::Prism.tree_for(@tmp_file)

      File.write(@tmp_file, "2")
      expect(Hecks::Adapters::Prism.tree_for(@tmp_file)).to equal(first),
                                                            "still cached — a rewrite alone must not invalidate it"

      Hecks::Adapters::Prism.forget(@tmp_file)
      expect(Hecks::Adapters::Prism.tree_for(@tmp_file)).not_to equal(first)
    end

    it "forget_all clears every cached tree, not just one path" do
      File.write(@tmp_file, "1")
      first = Hecks::Adapters::Prism.tree_for(@tmp_file)

      Hecks::Adapters::Prism.forget_all
      File.write(@tmp_file, "2")
      expect(Hecks::Adapters::Prism.tree_for(@tmp_file)).not_to equal(first)
    end

    it "forget on a path never cached is a no-op, not a raise" do
      expect { Hecks::Adapters::Prism.forget("/no/such/file.rb") }.not_to raise_error
    end
  end

  describe "caching" do
    let(:evaluator) { Hecks::Bluebook::Expression::Evaluator }

    it "parses a leaf expression's grammar once, no matter how many times its predicate runs" do
      expr = "amount > 0"
      evaluator.ast_cache.delete(expr)

      evaluate(expr, amount: 1)
      left_leaf = evaluator.ast_cache.fetch(expr).left

      evaluate(expr, amount: -1)
      evaluate(expr, amount: 0)

      expect(evaluator.ast_cache.fetch(expr).left).to equal(left_leaf)
    end

    it "parses a leaf's nested sub-expressions once too — the receiver of a sign test, not just the top" do
      expr = "amount.positive?"
      evaluator.ast_cache.delete(expr)

      evaluate(expr, amount: 1)
      sign_test = evaluator.ast_cache.fetch(expr).expr
      receiver_leaf = sign_test.receiver

      evaluate(expr, amount: -1)

      resolved_again = evaluator.ast_cache.fetch(expr).expr
      expect(resolved_again).to equal(sign_test)
      expect(resolved_again.receiver).to equal(receiver_leaf)
    end
  end

  # `interpret`'s own `case` in both Evaluator and Resolver used to have no
  # `else` at all — a node type `parse` never produces reaching it (today,
  # only possible from a hand-built AST, not real corpus text) would return
  # bare `nil` silently rather than refuse. Neither method's real `parse` can
  # produce a node outside its own known set, so this exercises the backstop
  # directly, past `parse`, the only way to reach it at all.
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

  # `Resolver#split_addition` counts braces toward depth exactly as it
  # counts parens — its own comment has the story. Before it did, a `+`
  # inside a block predicate's own body split the WHOLE expression as an
  # Addition, and the unparenthesized spelling below (the natural one, and
  # the one a downstream chess domain's castling given actually wrote)
  # died with "no implicit conversion of Symbol into Integer" while its
  # parenthesized twin worked — a trap distinguishable only by parens.
  describe "arithmetic inside a block predicate" do
    let(:attrs) do
      { kings:  [{ status: "on_board", square: { file: 6, rank: 0 } }],
        to:     { file: 5, rank: 0 },
        square: { file: 7, rank: 0 } }
    end

    it "parses a bare `+` inside the block body as the block's own arithmetic, not the expression's" do
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
end
