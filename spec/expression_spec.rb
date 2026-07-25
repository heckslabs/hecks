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
    Hecksagain::Expression::Evaluator.call(expression, state, args)
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

    # The trap this guards: a missing attribute resolves to null, coerces to 0,
    # and would report zero? as TRUE — quietly satisfying a predicate that
    # should have failed loudly.
    it "answers false for a value with no numeric reading" do
      expect(evaluate("missing.positive?")).to be(false)
      expect(evaluate("missing.negative?")).to be(false)
      expect(evaluate("missing.zero?")).to be(false)
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

  describe "extraction" do
    it "lowers a real Ruby block to canonical text" do
      canonical = Hecksagain::Expression::Extractor.canonical(proc { 1 < 2 })
      expect(canonical).to eq("1 < 2")
    end

    it "folds .length onto .size while extracting" do
      canonical = Hecksagain::Expression::Extractor.canonical(proc { [].length < 10 })
      expect(canonical).to include(".size")
    end
  end
end
