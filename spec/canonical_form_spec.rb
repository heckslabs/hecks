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
