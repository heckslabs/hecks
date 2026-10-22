require "spec_helper"
require "hecks/ports/persistence/plugins/era"

# `derive` end to end in Ruby: the word, the refusals it carries, and the in-process rewrite.
RSpec.describe "the derive rule" do
  def edge(&block)
    registry = Hecks::Runtime::Registry.new
    Hecks.with_registry(registry) { Hecks.data_translation("Directory", from: "aaaaaa", to: "bbbbbb", &block) }
    registry.translations.first
  end

  def translated(declared, state)
    entry = Hecks::Ports::Persistence::Entry.new(operation: "save", id: "m1", state: state, mirrors: nil)
    Hecks::Ports::Persistence::Lineage.from_declared(declared, "Member").translate(entry).state
  end

  def chained_derives
    edge do
      aggregate("Member") do
        derive :a, as: 'concat("x", "y")'
        derive :b, as: "upper(a)"
      end
    end.for_aggregate("Member")
  end

  let(:state) { { name: { "value" => "Chris Young" }, kind: { "label" => "biz" } } }

  let(:declared) do
    edge do
      aggregate "Member" do
        derive :email, as: 'concat(lower(replace(name.value, " ", ".")), "@x.io")'
        drop :name
      end
    end.for_aggregate("Member")
  end

  it "stores the destination and the expression's text" do
    expect(declared.derives.map(&:to_a)).to eq([["email", 'concat(lower(replace(name.value, " ", ".")), "@x.io")']])
  end

  it "computes the field from data the same edge drops" do
    expect(translated(declared, state)).to eq(kind: { "label" => "biz" }, email: "chris.young@x.io")
  end

  it "writes nothing when the expression has no value" do
    expect(translated(declared, { kind: "biz" })).to eq(kind: "biz")
  end

  it "reads every derive from the stored state, not from another derive's output" do
    expect(translated(chained_derives, {})).to eq(a: "xy")
  end

  it "nests under a value object when the destination is dotted" do
    nested = edge { aggregate("Member") { derive "contact.email", as: "lower(name.value)" } }.for_aggregate("Member")
    expect(translated(nested, state)).to include(contact: { "email" => "chris young" })
  end

  it "counts as the rule that fills its destination" do
    expect(Hecks::Ports::Persistence::Lineage.from_declared(declared, "Member").fills?(:email)).to be(true)
  end

  {
    proc { aggregate("Member") { derive "", as: "lower(a)" } } => "a derive needs a destination path",
    proc { aggregate("Member") { derive :a, as: "" } }         => "a derive needs its as: expression",
    proc { aggregate("Member") { derive :a, as: "nope(a)" } }  => /a derive's as: expression is refused: nope is not a function/,
    proc {
      aggregate("Member") do
        derive :a, as: "lower(b)"
        derive :a, as: "upper(b)"
      end
    }                                                          => "a is derived twice"
  }.each do |body, refusal|
    it "refuses #{refusal.inspect}" do
      expect { edge(&body) }.to raise_error(Hecks::Bluebook::DSL::Malformed, refusal)
    end
  end
end
