require "spec_helper"

# FLAT STRINGS IN, NESTED TYPED ARGUMENTS OUT — the translation a command line
# needs and `JsonDoor` does not, because JSON arrives already nested and
# already typed.
RSpec.describe Hecksagain::Facade::CliDoor do
  let(:spec) do
    { arguments: [
      { path: "id",                      type: "String"  },
      { path: "reference.value",         type: "String"  },
      { path: "sequence.value",          type: "Integer" },
      { path: "pizza.price_cents.cents", type: "Integer" },
      { path: "pizza.size.value",        type: "String"  },
      { path: "wanted",                  type: "Boolean" }
    ] }
  end

  it "rebuilds the nesting a dotted path spells" do
    expect(described_class.arguments(spec, ["reference.value=BUG#1"]))
      .to eq(reference: { value: "BUG#1" })
  end

  it "rebuilds nesting of any depth" do
    expect(described_class.arguments(spec, ["pizza.price_cents.cents=1500", "pizza.size.value=large"]))
      .to eq(pizza: { price_cents: { cents: 1500 }, size: { value: "large" } })
  end

  # THE TYPE COMES FROM THE PROJECTION, NEVER FROM THE VALUE. A door that
  # guessed would send the Integer 99 for a version string of "99" and be wrong
  # in a way nothing downstream could detect.
  describe "typing" do
    it "casts by the declared type, not by what the value looks like" do
      args = described_class.arguments(spec, ["sequence.value=99", "reference.value=99"])

      expect(args[:sequence][:value]).to eq(99)
      expect(args[:reference][:value]).to eq("99")
    end

    it "reads a boolean the ways a shell writes one" do
      expect(described_class.arguments(spec, ["wanted=true"])[:wanted]).to be(true)
      expect(described_class.arguments(spec, ["wanted=no"])[:wanted]).to be(false)
    end

    it "refuses a value the declared type cannot hold, naming the type" do
      expect { described_class.arguments(spec, ["sequence.value=soon"]) }
        .to raise_error(Hecksagain::Runtime::TypeMismatch, /"soon" is not Integer/)
    end
  end

  # ALMOST EVERY VALUE OBJECT IN THIS CORPUS HAS ONE FIELD, so the short form
  # is what anybody types.
  describe "the short form" do
    it "expands a value object with exactly one option beneath it" do
      expect(described_class.arguments(spec, ["reference=BUG#1"]))
        .to eq(reference: { value: "BUG#1" })
    end

    it "types the expanded form the same way" do
      expect(described_class.arguments(spec, ["sequence=99"])[:sequence][:value]).to eq(99)
    end

    # TWO CANDIDATES IS A GUESS ABOUT WHICH FIELD WAS MEANT, and a wrong guess
    # here is a silently misplaced value.
    it "refuses to guess when more than one option shares the prefix" do
      expect { described_class.arguments(spec, ["pizza=1500"]) }
        .to raise_error(Hecksagain::Runtime::NotFound, /no argument "pizza"/)
    end
  end

  describe "refusals" do
    it "names an argument the verb does not take, and lists the ones it does" do
      expect { described_class.arguments(spec, ["hwo=x"]) }
        .to raise_error(Hecksagain::Runtime::NotFound, /no argument "hwo".*this verb takes .*id/m)
    end

    it "refuses a bare word that is not name=value" do
      expect { described_class.arguments(spec, ["reference"]) }
        .to raise_error(Hecksagain::Runtime::NotFound, /is not name=value/)
    end

    it "keeps an = inside the value" do
      expect(described_class.arguments(spec, ["reference.value=a=b"]))
        .to eq(reference: { value: "a=b" })
    end
  end
end
