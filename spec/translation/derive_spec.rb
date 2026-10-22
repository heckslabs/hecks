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

  # rekey_to: the id is the value of a derive, and costs no approval.
  describe "rekey_to" do
    def rekeyed
      edge do
        aggregate "Member" do
          derive :email, as: 'concat(lower(replace(name.value, " ", ".")), "@x.io")'
          rekey_to :email
        end
      end.for_aggregate("Member")
    end

    def translated_id(declared, state)
      entry = Hecks::Ports::Persistence::Entry.new(operation: "save", id: "m1", state: state, mirrors: nil)
      Hecks::Ports::Persistence::Lineage.from_declared(declared, "Member").translate(entry).id
    end

    it "gives a record the value of its derive as its id" do
      expect(translated_id(rekeyed, { name: { "value" => "Chris Young" } })).to eq("chris.young@x.io")
    end

    it "keeps the old id where the derive has no value" do
      expect(translated_id(rekeyed, { kind: "biz" })).to eq("m1")
    end

    it "counts as a rekey, so the identity check is satisfied" do
      expect(Hecks::Ports::Persistence::Lineage.from_declared(rekeyed, "Member").rekey?).to be(true)
    end

    it "needs no approval, unlike a rekey written in SQL" do
      sql = edge { aggregate("Member") { rekey sql: "state->>'a'" } }.for_aggregate("Member")
      expect([rekeyed.needs_approval?, sql.needs_approval?]).to eq([false, true])
    end

    it "is left out of what an approval digests but exported with its field" do
      exported = Hecks::Projector::Exporter.send(:compiled_translation_aggregate, rekeyed)
      expect(exported).to include(rekeys: [], rekey_to: "email")
    end

    it "compiles the id to the derive's value or the old id" do
      expect(Hecks::Translation::RuleCompiler.compile_id_expression(rekeyed)).to start_with("COALESCE(")
    end

    def rekeyed_twice
      edge do
        aggregate("Member") do
          derive :a, as: "lower(b)"
          rekey_to :a
          rekey_to :a
        end
      end
    end

    it "is refused when the aggregate is rekeyed twice" do
      expect { rekeyed_twice }.to raise_error(Hecks::Bluebook::DSL::Malformed, "an aggregate is rekeyed once")
    end
  end
end
