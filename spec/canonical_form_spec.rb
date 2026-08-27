require "hecks"

RSpec.describe Hecks::Bluebook::Expression::CanonicalForm do
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

    it "leaves a non-breaking space alone — it is not ASCII whitespace" do
      nbsp = " "
      expect(described_class.apply("a#{nbsp}<#{nbsp}b")).to eq("a#{nbsp}<#{nbsp}b")
    end

    it "does not strip a leading non-breaking space either" do
      nbsp = " "
      expect(described_class.apply("#{nbsp}a < b")).to eq("#{nbsp}a < b")
    end

    it "folds .length to .size only at a word boundary" do
      expect(described_class.apply("items.length > 0")).to eq("items.size > 0")
      expect(described_class.apply("dims.length_cm > 0")).to eq("dims.length_cm > 0")
    end

    it "applies the rules in declared position order" do
      expect(described_class.apply("items.length   >   0")).to eq("items.size > 0")
    end

    # M7 (docs/audits/2026-08-10-main-bug-audit.md) — normalisation used to
    # be quote-blind, rewriting a string literal's own CONTENTS the same
    # as the surrounding source. A literal is data a predicate compares
    # against, not syntax to normalise — collapsing its whitespace or
    # folding `.length`→`.size` inside the quotes silently changes what
    # the predicate means.
    it "does not collapse whitespace inside a string literal" do
      expect(described_class.apply('name   ==   "a  b"')).to eq('name == "a  b"')
    end

    it "does not fold .length to .size inside a string literal" do
      expect(described_class.apply('label == "x.length"')).to eq('label == "x.length"')
    end

    it "still normalises the source around an untouched literal" do
      expect(described_class.apply('items.length   ==   "still  raw"')).to eq('items.size == "still  raw"')
    end

    it "treats single-quoted literals the same way" do
      expect(described_class.apply("name   ==   'a  b'")).to eq("name == 'a  b'")
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
