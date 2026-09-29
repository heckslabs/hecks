require "spec_helper"

# Flat strings in, nested typed arguments out — the translation a command line
# needs and `JsonDoor` does not, because JSON arrives already nested and
# already typed.
RSpec.describe Hecks::Facade::CliDoor do
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

  # The type comes from the projection, never from the value. A door that
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
        .to raise_error(Hecks::Runtime::TypeMismatch, /"soon" is not Integer/)
    end
  end

  # Almost every value object in this corpus has one field, so the short form
  # is what anybody types.
  describe "the short form" do
    it "expands a value object with exactly one option beneath it" do
      expect(described_class.arguments(spec, ["reference=BUG#1"]))
        .to eq(reference: { value: "BUG#1" })
    end

    it "types the expanded form the same way" do
      expect(described_class.arguments(spec, ["sequence=99"])[:sequence][:value]).to eq(99)
    end

    # Two candidates is a guess about which field was meant, and a wrong guess
    # here is a silently misplaced value.
    it "refuses to guess when more than one option shares the prefix" do
      expect { described_class.arguments(spec, ["pizza=1500"]) }
        .to raise_error(Hecks::Runtime::NotFound, /no argument "pizza"/)
    end
  end

  describe "the 3.0 short forms" do
    it "fills the verb's first argument from one bare word" do
      expect(described_class.arguments(spec, ["A-1", "sequence=99"])).to eq(id: "A-1", sequence: { value: 99 })
    end

    it "reads --name as true for a Boolean" do
      expect(described_class.arguments(spec, ["--wanted"])).to eq(wanted: true)
    end

    it "reads --name=value as name=value" do
      expect(described_class.arguments(spec, ["--reference=BUG#1"])).to eq(reference: { value: "BUG#1" })
    end

    it "still reads plain name=value exactly as before" do
      expect(described_class.arguments(spec, ["id=A-1", "wanted=no"])).to eq(id: "A-1", wanted: false)
    end
  end

  describe "refusals" do
    it "names an argument the verb does not take, and lists the ones it does" do
      expect { described_class.arguments(spec, ["hwo=x"]) }
        .to raise_error(Hecks::Runtime::NotFound, /no argument "hwo".*this verb takes .*id/m)
    end

    it "refuses more than one bare word, asking for the rest by name" do
      expect { described_class.arguments(spec, %w[A-1 B-2]) }
        .to raise_error(Hecks::Runtime::NotFound, /only one argument may go unnamed/)
    end

    it "refuses a bare word for a verb that takes no arguments" do
      expect { described_class.arguments({ arguments: [] }, ["A-1"]) }
        .to raise_error(Hecks::Runtime::NotFound, /is not name=value, and this verb takes no arguments/)
    end

    it "refuses a flag for an argument that is not Boolean" do
      expect { described_class.arguments(spec, ["--reference"]) }
        .to raise_error(Hecks::Runtime::NotFound, /--reference is a flag, but this verb has no Boolean/)
    end

    it "keeps an = inside the value" do
      expect(described_class.arguments(spec, ["reference.value=a=b"]))
        .to eq(reference: { value: "a=b" })
    end
  end
end
