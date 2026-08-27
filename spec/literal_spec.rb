require "spec_helper"

# The wire spelling itself, held still.
#
# Every other spec that touches these strings reaches them through a domain
# boot, so the only thing pinning the FORMAT was a golden file — and a golden
# regenerates. This is the claim: these exact spellings, on any Ruby. The
# renderings this replaced were `Hash#inspect` and `Symbol#to_s`, which meant
# the wire format quietly said whatever the interpreter said — 3.3 spells the
# same Hash `{:k=>"v"}` and 3.4 spells it `{k: "v"}`.
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

    # The exact regression `render_value`'s old `.to_s`-for-everything
    # collapse produced: a numeric-LOOKING string wears its own quotes on
    # the wire rather than being indistinguishable from the bare digits a
    # real Integer renders as ("007" used to cross the wire as the text
    # `007`, identical to what `7` itself would have written, and came
    # back an Integer on the other side — `where code == "007"` then
    # matched nothing).
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

    # `{}` renders "{}" and reads back as nil-free but EMPTY — asserted apart
    # from the loop above only because an empty Hash and an empty Array are the
    # two values whose spellings a naive splitter turns into a one-item list.
    it "reads an empty object back as an empty object" do
      expect(described_class.read("{}")).to eq({})
    end

    # A comma inside a quoted value is not a separator. `where(status: { in:
    # "open,frozen" })` is a real clause in banking, and splitting on ", " tore
    # every nested field after the first one in half.
    it "keeps a quoted comma out of the split" do
      expect(described_class.read('{note: "a, b", other: 1}')).to eq(note: "a, b", other: 1)
    end

    # M15 — an EMBEDDED QUOTE inside an object literal's own string field.
    # `quote`/`unquote` escape and unescape it (`ESCAPED`), and `split_items`
    # tracks `quoting`/`escaping` state char by char rather than splitting on a
    # bare `"`, so `{text: "a \"quoted\" word"}` neither ends the field early
    # nor corrupts the split into a following field. Exercised through
    # `.render` first — the exact string a real default/binding would carry
    # on the wire — not hand-written, so this is the real encoding, not a
    # convenient one.
    it "keeps an embedded, escaped quote inside a quoted field rather than ending it early" do
      value = { text: 'a "quoted" word' }

      expect(described_class.read(described_class.render(value))).to eq(value)
    end

    # THE SAME SHAPE ONE FIELD LATER — an embedded quote must not corrupt a
    # SIBLING field's own read either, which a naive quote-blind scanner
    # (ending the string at the first `"` it sees) would have done by
    # treating the field's own closing quote as the embedded one and reading
    # everything after it — including the next field's name — as more text.
    it "keeps an embedded quote from corrupting the field that follows it" do
      value = { note: 'say "hi"', other: 1 }

      expect(described_class.read(described_class.render(value))).to eq(value)
    end

    # The language stores a closed set's members and a few other fields as text
    # nothing ever rendered, so a bare word has to stay the word it is.
    it "leaves an unrendered bare word alone" do
      expect(described_class.read("high_risk")).to eq("high_risk")
    end

    # The read-side half of the same regression: a real render'd numeric
    # string round-trips as the STRING it was, not the Integer its digits
    # happen to spell.
    it "reads a rendered numeric-looking string back as a string, not a number" do
      expect(described_class.read(described_class.render("007"))).to eq("007")
    end
  end
end
