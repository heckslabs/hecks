require "spec_helper"

# The expression language of a `derive` rule: what parses, what it computes, and what it refuses.
RSpec.describe Hecks::Bluebook::TranslationExpression do
  def parse(text) = described_class.parse(text)

  def run(text, state) = described_class.evaluate(parse(text), state)

  let(:member) { { name: { "value" => "Chris Young" }, kind: "Biz" } }

  it "parses a reference, a literal and a function into the plan form" do
    expect(parse('concat(lower(name.value), "@x.io")')).to eq(
      ["concat", ["lower", ["ref", "name.value"]], ["lit", "@x.io"]]
    )
  end

  it "reads a nested path and joins text" do
    expect(run('concat(lower(replace(name.value, " ", ".")), "@x.io")', member)).to eq("chris.young@x.io")
  end

  it "folds case for ASCII only" do
    expect(run("upper(kind)", { kind: "straße" })).to eq("STRAßE")
  end

  it "maps through a lookup table and falls back to the literal" do
    text = 'lookup(kind, {"Biz": "business"}, "other")'
    expect([run(text, member), run(text, { kind: "Pers" })]).to eq(%w[business other])
  end

  it "gives no value for a missing or non-text reference" do
    expect([run("lower(missing)", member), run("lower(name)", member)]).to eq([nil, nil])
  end

  it "gives no value when a lookup falls through to null" do
    expect(run('lookup(kind, {"Z": "z"}, null)', member)).to be_nil
  end

  it "treats a replacement as plain text" do
    expect(run('replace(kind, "i", "\\\\0")', member)).to eq("B\\0z")
  end

  {
    "chris(name)"                           => /chris is not a function/,
    "lower(a, b)"                           => /lower takes 1 expressions, not 2/,
    "concat(a)"                             => /concat takes two or more/,
    'replace(a, "", "x")'                   => /cannot look for an empty string/,
    "replace(a, b, \"x\")"                  => /needs string literals/,
    "lookup(a, {}, null)"                   => /expected a string/,
    'lookup(a, {"k": "v", "k": "w"}, null)' => /repeats a key/,
    'lookup(a, {"k": "v"}, b)'              => /string literal or null as its fallback/,
    "lower(a) trailing"                     => /unexpected/,
    ""                                      => /expected a field/
  }.each do |text, refusal|
    it "refuses #{text.inspect}" do
      expect { parse(text) }.to raise_error(Hecks::Bluebook::TranslationExpression::Refused, refusal)
    end
  end
end
