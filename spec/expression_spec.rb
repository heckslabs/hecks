# The expression sublanguage — the subset of Ruby a predicate may be.
#
# These examples pin the SPEC, not one runtime's reading of it. Every rule here
# has a twin in rust/src/interp_expr.rs and interp_givens.rs, and bin/parity is
# what proves the twin agrees. When one of these changes, the Rust side changes
# with it in the same commit — an operator that only one runtime understands is
# not an operator.
require "hecksagain"

RSpec.describe "the expression sublanguage" do
  def evaluate(expression, state = {}, args = {})
    Hecksagain::Language::Expression::Evaluator.call(expression, state, args)
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

    # This once answered FALSE for all three, which was the bug wearing the
    # costume of a guard: a missing attribute coerced to 0, so `.zero?` would
    # have reported TRUE and quietly satisfied the rule it was meant to
    # enforce. Ruby raises on nil.positive? and so does this.
    it "raises rather than answering for a name it cannot resolve" do
      %w[positive? negative? zero?].each do |test|
        expect { evaluate("missing.#{test}") }
          .to raise_error(Hecksagain::Language::Expression::EvaluationError, /cannot resolve "missing"/)
      end
    end
  end

  describe "precedence" do
    # This is the rule that most needs pinning. `a || b && c` means
    # `a || (b && c)` ONLY because || splits first. A runtime that split &&
    # first would answer differently and look correct in isolation.
    it "binds || looser than &&" do
      expect(evaluate("true || false && false")).to be(true)
      expect(evaluate("(true || false) && false")).to be(false)
    end

    it "keeps parens that do not wrap the whole expression" do
      expect(evaluate("(1 < 2) && (3 < 4)")).to be(true)
      expect(evaluate("(1 < 2) && (4 < 3)")).to be(false)
    end

    # A splitter that matched > inside >= would cut the text mid-comparison
    # and invert the verdict.
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

  # THE CLAIM THE WORD "SUBLANGUAGE" MAKES.
  #
  # A sublanguage of Ruby must MEAN what Ruby means. Each case below is
  # evaluated twice — once by the sublanguage, once by Ruby itself — and the
  # two must land in the same place. An earlier reading of this file agreed
  # with Ruby on one case out of six: 0 was falsy, "" was falsy, and 1 == "1"
  # was true, so `given { count }` read as "when there are some" and fired when
  # there were none.
  describe "agreeing with Ruby itself" do
    def agrees?(expression, bindings)
      mine = begin
        evaluate(expression, bindings)
      rescue Hecksagain::Language::Expression::EvaluationError
        :raised
      end

      theirs = begin
        locals = bindings.map { |name, value| "#{name} = #{value.inspect}; " }.join
        eval("#{locals}#{expression}") # rubocop:disable Security/Eval
      rescue StandardError
        :raised
      end

      # Ruby yields a value ; the sublanguage yields that value's truth.
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
        .to raise_error(Hecksagain::Language::Expression::EvaluationError, /comparison of String with 3 failed/)
    end

    it "orders strings against strings" do
      expect(evaluate('label < "b"', label: "a")).to be(true)
      expect(evaluate('label < "b"', label: "c")).to be(false)
    end
  end

  # A predicate that cannot be evaluated is a defect, not a false. Answering
  # nil would let a typo coerce to 0 and quietly satisfy the very rule it was
  # meant to enforce.
  describe "refusing what it cannot evaluate" do
    it "raises on a name it cannot resolve" do
      expect { evaluate("mispelled_attribute > 0") }
        .to raise_error(Hecksagain::Language::Expression::EvaluationError, /cannot resolve "mispelled_attribute"/)
    end

    it "raises when a sign predicate has no number" do
      expect { evaluate("label.positive?", { label: "abc" }) }
        .to raise_error(Hecksagain::Language::Expression::EvaluationError, /positive\? expects a number/)
    end

    it "raises when size has nothing to count" do
      expect { evaluate("count.size", { count: 3 }) }
        .to raise_error(Hecksagain::Language::Expression::EvaluationError, /size expects a list or string/)
    end

    it "still resolves a declared attribute that happens to be nil" do
      expect(evaluate("customer_name == nil", { customer_name: nil })).to be(true)
    end
  end

  describe "extraction" do
    it "lowers a real Ruby block to canonical text" do
      canonical = Hecksagain::Language::Expression::Extractor.canonical(proc { 1 < 2 })
      expect(canonical).to eq("1 < 2")
    end

    it "folds .length onto .size while extracting" do
      canonical = Hecksagain::Language::Expression::Extractor.canonical(proc { [].length < 10 })
      expect(canonical).to include(".size")
    end
  end
end
