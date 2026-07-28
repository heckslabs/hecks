require "hecksagain"

RSpec.describe "the expression sublanguage" do
  def evaluate(expression, state = {}, args = {})
    Hecksagain::Bluebook::Expression::Evaluator.call(expression, state, args)
  end

  describe "literals" do
    it "reads integers, quoted strings, and booleans" do
      expect(evaluate("1 < 2")).to be(true)
      expect(evaluate('"a" == "a"')).to be(true)
      expect(evaluate("true")).to be(true)
      expect(evaluate("false")).to be(false)
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
          .to raise_error(Hecksagain::Bluebook::Expression::EvaluationError, /cannot resolve "missing"/)
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

  describe "agreeing with Ruby itself" do
    def agrees?(expression, bindings)
      mine = begin
        evaluate(expression, bindings)
      rescue Hecksagain::Bluebook::Expression::EvaluationError
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

    it "refuses an incomparable ordering, exactly as Ruby does" do
      expect(agrees?("label < 3", label: "abc")).to be(true)
      expect { evaluate("label < 3", label: "abc") }
        .to raise_error(Hecksagain::Bluebook::Expression::EvaluationError, /comparison of String with 3 failed/)
    end

    it "orders strings against strings" do
      expect(evaluate('label < "b"', label: "a")).to be(true)
      expect(evaluate('label < "b"', label: "c")).to be(false)
    end
  end

  describe "refusing what it cannot evaluate" do
    it "raises on a name it cannot resolve" do
      expect { evaluate("mispelled_attribute > 0") }
        .to raise_error(Hecksagain::Bluebook::Expression::EvaluationError, /cannot resolve "mispelled_attribute"/)
    end

    it "raises when a sign predicate has no number" do
      expect { evaluate("label.positive?", { label: "abc" }) }
        .to raise_error(Hecksagain::Bluebook::Expression::EvaluationError, /positive\? expects a number/)
    end

    it "raises when size has nothing to count" do
      expect { evaluate("count.size", { count: 3 }) }
        .to raise_error(Hecksagain::Bluebook::Expression::EvaluationError, /size expects a list or string/)
    end

    it "still resolves a declared attribute that happens to be nil" do
      expect(evaluate("customer_name == nil", { customer_name: nil })).to be(true)
    end
  end

  describe "extraction" do
    it "lowers a real Ruby block to canonical text" do
      canonical = Hecksagain::Adapters::Prism.canonical(proc { 1 < 2 })
      expect(canonical).to eq("1 < 2")
    end

    it "folds .length onto .size while extracting" do
      canonical = Hecksagain::Adapters::Prism.canonical(proc { [].length < 10 })
      expect(canonical).to include(".size")
    end
  end
end
