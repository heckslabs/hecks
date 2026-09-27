require "spec_helper"

# Pins the exact wire spellings, independent of the Ruby version (`Hash#inspect`
# differs between 3.3 and 3.4, and a golden file regenerates).
RSpec.describe Hecks::Literal do
  describe ".render" do
    {
      nil                       => "nil",
      true                      => "true",
      false                     => "false",
      0                         => "0",
      -12                       => "-12",
      1.5                       => "1.5",
      :amount                   => ":amount",
      "open"                    => '"open"',
      { value: "credit" }       => '{value: "credit"}',
      { cents: 0 }              => "{cents: 0}",
      { a: 1, b: :two }         => "{a: 1, b: :two}",
      { outer: { inner: "x" } } => '{outer: {inner: "x"}}',
      %w[open frozen]           => '["open", "frozen"]',
      {}                        => "{}",
      []                        => "[]"
    }.each do |value, spelling|
      it "spells #{value.inspect} as #{spelling}" do
        expect(described_class.render(value)).to eq(spelling)
      end
    end

    it "refuses a type it has no pinned spelling for, rather than letting to_s decide" do
      expect { described_class.render(Object.new) }.to raise_error(ArgumentError, /no pinned literal spelling/)
    end

    # A numeric-looking string keeps its quotes; bare `007` would read back as an
    # Integer and `where code == "007"` would match nothing.
    it "quotes a numeric-looking string differently from the number itself" do
      expect(described_class.render("007")).to eq('"007"')
      expect(described_class.render(7)).to eq("7")
    end
  end

  describe ".read" do
    [nil, true, false, 0, -12, 1.5, :amount, "open", { value: "credit" }, { cents: 0 },
     { a: 1, b: :two }, { outer: { inner: "x" } }, %w[open frozen], []].each do |value|
      it "reads #{value.inspect} back out of its own spelling" do
        expect(described_class.read(described_class.render(value))).to eq(value)
      end
    end

    # Asserted apart: a naive splitter turns an empty object's spelling into a one-item list.
    it "reads an empty object back as an empty object" do
      expect(described_class.read("{}")).to eq({})
    end

    # A comma inside a quoted value is not a separator (`where(status: { in: "open,frozen" })`).
    it "keeps a quoted comma out of the split" do
      expect(described_class.read('{note: "a, b", other: 1}')).to eq(note: "a, b", other: 1)
    end

    # `split_items` tracks quoting and escaping, so an escaped embedded quote neither
    # ends the field early nor corrupts the next one. Built via `.render`, not by hand.
    it "keeps an embedded, escaped quote inside a quoted field rather than ending it early" do
      value = { text: 'a "quoted" word' }

      expect(described_class.read(described_class.render(value))).to eq(value)
    end

    # The same, with a sibling field after the embedded quote.
    it "keeps an embedded quote from corrupting the field that follows it" do
      value = { note: 'say "hi"', other: 1 }

      expect(described_class.read(described_class.render(value))).to eq(value)
    end

    # Closed-set members are stored as text nothing rendered, so a bare word stays as is.
    it "leaves an unrendered bare word alone" do
      expect(described_class.read("high_risk")).to eq("high_risk")
    end

    # The read side of the numeric-string case above.
    it "reads a rendered numeric-looking string back as a string, not a number" do
      expect(described_class.read(described_class.render("007"))).to eq("007")
    end
  end
end
