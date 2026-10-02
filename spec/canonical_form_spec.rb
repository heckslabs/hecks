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

    # A literal is data a predicate compares against, not syntax: normalising inside
    # the quotes would silently change what the predicate means.
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

    # A duration written as a call on a whole number is that many seconds (ADR 0081), so a
    # lifetime reads as `issued_at + days(730) > now` and both engines see the same integer.
    describe "durations" do
      it "folds days, hours and minutes into seconds" do
        expect(described_class.apply("issued_at.value + days(730) > now.value"))
          .to eq("issued_at.value + 63072000 > now.value")
        expect(described_class.apply("a + hours(2) < b")).to eq("a + 7200 < b")
        expect(described_class.apply("since + minutes(15) <= now")).to eq("since + 900 <= now")
      end

      it "reads the call whatever the spacing inside it" do
        expect(described_class.apply("a + days( 1 ) < b")).to eq("a + 86400 < b")
      end

      it "leaves a call on anything but a whole-number literal as written" do
        expect(described_class.apply("days(n) > 0")).to eq("days(n) > 0")
        expect(described_class.apply("days(1.5) > 0")).to eq("days(1.5) > 0")
      end

      it "leaves a method call and a longer name alone" do
        expect(described_class.apply("x.days(3) == 1")).to eq("x.days(3) == 1")
        expect(described_class.apply("workdays(3) > 0")).to eq("workdays(3) > 0")
      end

      it "does not fold inside a string literal" do
        expect(described_class.apply('label == "days(3)"')).to eq('label == "days(3)"')
      end
    end
  end

  # The cases the Rust parser's tests read too: one table, so the two engines' canonical forms
  # cannot drift apart on a case written there.
  describe "the cases both engines read" do
    cases = JSON.parse(File.read(File.join(__dir__, "fixtures/canonical_form_cases.json"))).fetch("cases")

    cases.each do |row|
      it "gives #{row['source'].inspect} the canonical form #{row['canonical'].inspect}" do
        expect(described_class.apply(row["source"])).to eq(row["canonical"])
      end
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
