# THE NORMALISATION TABLE, and the strategies behind it.
#
# The TABLE is already in the parity contract — both runtimes emit RULES into
# the IR they are diffed on, so a divergence between the two tables shows up as
# a SPLIT. The STRATEGIES are not: `collapse_whitespace` and `replace` are
# linked code on each side, named by the row but implemented twice.
#
# So they are pinned here, and mirrored in rust/src/projector/ir_json.rs. This
# is the seam the `.length_cm` bug came through — one shared rule, two honest
# implementations that differed — and it stayed open after that fix, because
# what counts as WHITESPACE was still each language's own idea.
require "hecksagain"

RSpec.describe Hecksagain::Bluebook::Expression::CanonicalForm do
  describe ".apply" do
    it "collapses a run of spaces to one" do
      expect(described_class.apply("a   <   b")).to eq("a < b")
    end

    it "collapses tabs and newlines the same way" do
      expect(described_class.apply("a\t<\n\nb")).to eq("a < b")
    end

    it "strips the ends" do
      expect(described_class.apply("  a < b  ")).to eq("a < b")
    end

    # WHAT COUNTS AS WHITESPACE. Ruby's `\s` and `String#strip` are ASCII-only.
    # Rust reached for `split_whitespace` and `trim`, which are Unicode-aware,
    # so a non-breaking space — what you get pasting a predicate out of a
    # document — collapsed on one side and survived on the other. The canonical
    # text is what gets hashed and diffed, so that is a latent parity SPLIT.
    # Ruby holds the semantics: a non-breaking space is a character, not space.
    it "leaves a non-breaking space alone — it is not ASCII whitespace" do
      nbsp = " "
      expect(described_class.apply("a#{nbsp}<#{nbsp}b")).to eq("a#{nbsp}<#{nbsp}b")
    end

    it "does not strip a leading non-breaking space either" do
      nbsp = " "
      expect(described_class.apply("#{nbsp}a < b")).to eq("#{nbsp}a < b")
    end

    # `boundary: "word"` — the rule that already cost one split.
    it "folds .length to .size only at a word boundary" do
      expect(described_class.apply("items.length > 0")).to eq("items.size > 0")
      expect(described_class.apply("dims.length_cm > 0")).to eq("dims.length_cm > 0")
    end

    it "applies the rules in declared position order" do
      expect(described_class.apply("items.length   >   0")).to eq("items.size > 0")
    end
  end

  describe ".step" do
    it "refuses a strategy no target has linked" do
      rogue = described_class::Rule.new(
        strategy: "invent_something", source_token: "", replacement: "",
        boundary: "none", position: 1
      )

      expect { described_class.step("a", rogue) }.to raise_error(ArgumentError, /not a linked/)
    end
  end
end
