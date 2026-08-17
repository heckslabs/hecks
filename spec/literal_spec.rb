require "spec_helper"

# The wire spelling itself, held still.
#
# Every other spec that touches these strings reaches them through a domain
# boot, so the only thing pinning the FORMAT was a golden file — and a golden
# regenerates. This is the claim: these exact spellings, on any Ruby. The
# renderings this replaced were `Hash#inspect` and `Symbol#to_s`, which meant
# the wire format quietly said whatever the interpreter said — 3.3 spells the
# same Hash `{:k=>"v"}` and 3.4 spells it `{k: "v"}`.
RSpec.describe Hecksagain::Literal do
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

    # The language stores a closed set's members and a few other fields as text
    # nothing ever rendered, so a bare word has to stay the word it is.
    it "leaves an unrendered bare word alone" do
      expect(described_class.read("high_risk")).to eq("high_risk")
    end
  end
end
